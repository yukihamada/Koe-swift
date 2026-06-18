import AppKit
import AVFoundation
import Vision

/// カメラ + Vision の手ポーズ検出で、音声を補完する無声ジェスチャーを認識する。
///
/// オンデバイス（VNDetectHumanHandPoseRequest）でフレームは外に出さない。
/// 継続会話セッション中のみ稼働（ConversationSession が start/stop する）。
/// ポーズは一定時間ホールドで確定＋クールダウン（誤爆＝ウェイクワード誤爆の手版を抑制）。
final class GestureEngine: NSObject {
    static let shared = GestureEngine()

    enum Gesture: Equatable {
        case thumbsUp        // 👍 OK / はい
        case thumbsDown      // 👎 やめて
        case openPalm        // ✋ 停止 / ESC
        case fingers(Int)    // ✌️ 指 N 本 → 番号 #N
        case swipeUp         // ↑ スクロール上
        case swipeDown       // ↓ スクロール下
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.yuki.koe.gesture")
    private let output = AVCaptureVideoDataOutput()
    private let request = VNDetectHumanHandPoseRequest()
    private(set) var isRunning = false

    // 確定用のホールド/クールダウン
    private var lastPose: Gesture?
    private var poseHoldCount = 0
    private let holdFramesNeeded = 4          // ~400ms @ 10fps
    private var cooldownUntil = Date.distantPast
    private let cooldown: TimeInterval = 1.2

    // スワイプ検出用の手首 Y 履歴
    private var wristHistory: [(t: Date, y: CGFloat)] = []

    private override init() {
        super.init()
        request.maximumHandCount = 1
    }

    // MARK: ライフサイクル

    func start() {
        guard !isRunning else { return }
        ensureCameraPermission { [weak self] granted in
            guard let self, granted else {
                klog("GestureEngine: カメラ権限なし")
                return
            }
            self.queue.async { self.configureAndRun() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
        lastPose = nil; poseHoldCount = 0; wristHistory = []
        klog("GestureEngine: stopped")
    }

    private func configureAndRun() {
        if session.inputs.isEmpty {
            session.beginConfiguration()
            session.sessionPreset = .medium   // 手ポーズ検出に十分な解像・省電力
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                klog("GestureEngine: カメラを開けません")
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            output.setSampleBufferDelegate(self, queue: queue)
            output.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        }
        if !session.isRunning { session.startRunning() }
        isRunning = true
        klog("GestureEngine: started")
    }

    private func ensureCameraPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { completion(ok) } }
        default:
            completion(false)
        }
    }

    // MARK: ジェスチャーの実行

    private func fire(_ gesture: Gesture) {
        cooldownUntil = Date().addingTimeInterval(cooldown)
        DispatchQueue.main.async {
            klog("GestureEngine: \(gesture)")
            switch gesture {
            case .thumbsUp:   ConversationSession.shared.gestureAffirm()
            case .thumbsDown: ConversationSession.shared.gestureCancel()
            case .openPalm:   ConversationSession.shared.endSession(reason: "gesture-palm")
            case .swipeUp:    ScrollSynthesizer.scroll(.up); NumberOverlayController.shared.refreshIfVisible()
            case .swipeDown:  ScrollSynthesizer.scroll(.down); NumberOverlayController.shared.refreshIfVisible()
            case .fingers(let n):
                if NumberOverlayController.shared.isVisible {
                    NumberOverlayController.shared.click(number: n)
                } else {
                    NumberOverlayController.shared.show()
                }
            }
        }
    }
}

// MARK: - フレーム処理 & ポーズ分類

extension GestureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else {
            resetPose(); return
        }
        classify(observation)
    }

    private func resetPose() {
        lastPose = nil
        poseHoldCount = 0
    }

    private func classify(_ obs: VNHumanHandPoseObservation) {
        guard Date() >= cooldownUntil else { return }
        guard let points = try? obs.recognizedPoints(.all) else { return }
        func pt(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence > 0.3 else { return nil }
            return p.location
        }
        guard let wrist = pt(.wrist) else { resetPose(); return }

        // 各指の伸展判定（tip が wrist から pip より遠い＝伸びている）
        func extended(_ tip: VNHumanHandPoseObservation.JointName,
                      _ pip: VNHumanHandPoseObservation.JointName) -> Bool? {
            guard let t = pt(tip), let p = pt(pip) else { return nil }
            return dist(t, wrist) > dist(p, wrist) * 1.05
        }
        let index  = extended(.indexTip,  .indexPIP)
        let middle = extended(.middleTip, .middlePIP)
        let ring   = extended(.ringTip,   .ringPIP)
        let little = extended(.littleTip, .littlePIP)
        let thumb  = extended(.thumbTip,  .thumbIP)

        let fingerCount = [index, middle, ring, little].compactMap { $0 }.filter { $0 }.count
        let thumbExtended = thumb ?? false

        // スワイプ（手首の縦移動）を先に判定
        if let swipe = detectSwipe(wristY: wrist.y) {
            confirm(swipe)
            return
        }

        var gesture: Gesture?
        if fingerCount >= 4 && thumbExtended {
            gesture = .openPalm                       // ✋ 全開
        } else if !thumbExtended && fingerCount >= 1 && fingerCount <= 4 {
            gesture = .fingers(fingerCount)           // ✌️ 指 N 本
        } else if thumbExtended && fingerCount == 0 {
            // 親指の向きで up/down（Vision: 原点 bottom-left, y up）
            if let tipP = pt(.thumbTip) {
                gesture = tipP.y >= wrist.y ? .thumbsUp : .thumbsDown
            }
        }

        if let g = gesture { confirm(g) } else { resetPose() }
    }

    /// ポーズを holdFramesNeeded 連続で確定したら fire。
    private func confirm(_ gesture: Gesture) {
        if gesture == lastPose {
            poseHoldCount += 1
        } else {
            lastPose = gesture
            poseHoldCount = 1
        }
        if poseHoldCount >= holdFramesNeeded {
            poseHoldCount = 0
            lastPose = nil
            fire(gesture)
        }
    }

    /// 手首 Y の急な縦移動でスワイプを検出。
    private func detectSwipe(wristY: CGFloat) -> Gesture? {
        let now = Date()
        wristHistory.append((now, wristY))
        wristHistory.removeAll { now.timeIntervalSince($0.t) > 0.5 }
        guard wristHistory.count >= 3,
              let first = wristHistory.first, let last = wristHistory.last else { return nil }
        let dy = last.y - first.y
        guard abs(dy) > 0.25 else { return nil }   // 画面高の 25% 以上の移動
        wristHistory.removeAll()
        // Vision: y up。上に動いた(dy>0) = swipeUp
        return dy > 0 ? .swipeUp : .swipeDown
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
