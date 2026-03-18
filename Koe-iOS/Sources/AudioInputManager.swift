import Foundation
import AVFoundation
import Combine

/// Manages audio input selection for external interfaces (Babyface Pro, iRig, etc.)
/// via Lightning/USB-C. Monitors route changes and auto-switches to external input.
@MainActor
final class AudioInputManager: ObservableObject {
    static let shared = AudioInputManager()

    @Published var availableInputs: [AVAudioSessionPortDescription] = []
    @Published var currentInput: String = "Built-in Mic"
    @Published var isExternalInput = false

    private var routeChangeObserver: NSObjectProtocol?

    init() {
        refreshInputs()
        observeRouteChanges()
    }

    deinit {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Refresh the list of available audio inputs from AVAudioSession.
    func refreshInputs() {
        let session = AVAudioSession.sharedInstance()
        availableInputs = session.availableInputs ?? []
        updateCurrentInputLabel()

        // Auto-select external input if detected
        if let external = availableInputs.first(where: { isExternalPort($0) }) {
            selectInput(external)
        }
    }

    /// Switch to a specific audio input port.
    func selectInput(_ port: AVAudioSessionPortDescription) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setPreferredInput(port)
            updateCurrentInputLabel()
            print("[Koe] AudioInputManager: selected input \(port.portName)")
        } catch {
            print("[Koe] AudioInputManager: failed to select input: \(error)")
        }
    }

    /// Configure AVAudioSession for instrument input (low latency, no processing).
    /// Call this when an external audio interface is connected and user wants
    /// clean instrument signal (guitar, synth, etc.).
    func configureForInstrument() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Use .measurement mode to disable AGC and noise suppression
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])

            // Set buffer to 128 samples for lowest latency (~2.9ms at 44.1kHz)
            try session.setPreferredIOBufferDuration(128.0 / 44100.0)

            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("[Koe] AudioInputManager: configured for instrument (low-latency, no AGC)")
        } catch {
            print("[Koe] AudioInputManager: instrument config failed: \(error)")
        }
    }

    /// Reset to default voice recording configuration.
    func configureForVoice() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setPreferredIOBufferDuration(0) // system default
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("[Koe] AudioInputManager: configured for voice")
        } catch {
            print("[Koe] AudioInputManager: voice config failed: \(error)")
        }
    }

    // MARK: - Private

    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.refreshInputs()
            }

            // Log reason for debugging
            if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               let reasonEnum = AVAudioSession.RouteChangeReason(rawValue: reason) {
                switch reasonEnum {
                case .newDeviceAvailable:
                    print("[Koe] AudioInputManager: new device connected")
                case .oldDeviceUnavailable:
                    print("[Koe] AudioInputManager: device disconnected")
                default:
                    break
                }
            }
        }
    }

    private func updateCurrentInputLabel() {
        let session = AVAudioSession.sharedInstance()
        if let preferred = session.preferredInput {
            currentInput = preferred.portName
            isExternalInput = isExternalPort(preferred)
        } else if let current = session.currentRoute.inputs.first {
            currentInput = current.portName
            isExternalInput = isExternalPort(current)
        } else {
            currentInput = "Built-in Mic"
            isExternalInput = false
        }
    }

    private func isExternalPort(_ port: AVAudioSessionPortDescription) -> Bool {
        let externalTypes: Set<AVAudioSession.Port> = [
            .usbAudio,
            .headsetMic,
            .lineIn,
            .bluetoothHFP,
            .bluetoothA2DP,
            .bluetoothLE,
        ]
        return externalTypes.contains(port.portType)
    }

}
