import CoreLocation

/// 録音開始時に現在地を一度だけ取得し、人が読める地名に逆ジオコーディングする。
/// VoiceMemos.app と同じ発想(「渋谷区」のように録音した場所がひと目でわかる)。
/// 権限なし/オフ/取得失敗はすべて黙ってスキップする(位置情報は付加情報であり、録音の成否には影響させない)。
final class LocationTagger: NSObject, CLLocationManagerDelegate {
    static let shared = LocationTagger()

    private let manager = CLLocationManager()
    private var completion: ((String?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// 現在地を1回だけ取得して地名を返す。完了は必ず1回呼ばれる(タイムアウト/失敗時は nil)。
    func tagCurrentLocation(completion: @escaping (String?) -> Void) {
        guard AppSettings.shared.voiceMemoLocationEnabled else {
            completion(nil)
            return
        }
        let status = manager.authorizationStatus
        switch status {
        case .denied, .restricted:
            completion(nil)
            return
        case .notDetermined:
            self.completion = completion
            manager.requestWhenInUseAuthorization()
            // 許可ダイアログの応答は authorizationStatus のコールバックで拾う(下の didChangeAuthorization)
            return
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            startOneShot(completion: completion)
        @unknown default:
            completion(nil)
        }
    }

    private func startOneShot(completion: @escaping (String?) -> Void) {
        self.completion = completion
        timeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        manager.requestLocation()
    }

    private func finish(_ placeName: String?) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let cb = completion
        completion = nil
        cb?(placeName)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let pending = completion else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            startOneShot(completion: pending)
        case .denied, .restricted:
            finish(nil)
        case .notDetermined:
            break
        @unknown default:
            finish(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { finish(nil); return }
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            let name = placemarks?.first.flatMap(Self.displayName)
            self?.finish(name)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        klog("LocationTagger: didFailWithError \(error.localizedDescription)")
        finish(nil)
    }

    /// 一番それらしい粒度を選ぶ: 施設名 > 地域(市区町村)の順。
    private static func displayName(_ p: CLPlacemark) -> String? {
        p.name ?? p.locality ?? p.subLocality ?? p.administrativeArea
    }
}
