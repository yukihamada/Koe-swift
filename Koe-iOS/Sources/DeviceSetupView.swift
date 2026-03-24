import SwiftUI
import CoreBluetooth
import NetworkExtension

/// Koe DeviceのBLEセットアップ画面
struct DeviceSetupView: View {
    @StateObject private var scanner = BLEDeviceScanner()
    @State private var selectedDevice: CBPeripheral?
    @State private var ssid = ""
    @State private var password = ""
    @State private var showPasswordField = false
    @State private var setupState: SetupState = .scanning

    enum SetupState {
        case scanning, connecting, enterWiFi, sending, done, error(String)
    }

    var body: some View {
        List {
            Section {
                switch setupState {
                case .scanning:
                    scanningView
                case .connecting:
                    HStack {
                        ProgressView().padding(.trailing, 8)
                        Text("接続中...")
                    }
                case .enterWiFi:
                    wifiInputView
                case .sending:
                    HStack {
                        ProgressView().padding(.trailing, 8)
                        Text("WiFi設定を送信中...")
                    }
                case .done:
                    Label("セットアップ完了!", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.headline)
                case .error(let msg):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("エラー", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(msg).font(.caption).foregroundColor(.secondary)
                        Button("再試行") {
                            setupState = .scanning
                            scanner.startScan()
                        }
                    }
                }
            } header: {
                Text("Koe Device セットアップ")
            } footer: {
                Text("Koe DeviceのLEDが青く点滅していることを確認してください。")
            }

            if !scanner.connectedDeviceInfo.isEmpty {
                Section("デバイス情報") {
                    ForEach(scanner.connectedDeviceInfo, id: \.key) { key, value in
                        HStack {
                            Text(key).foregroundColor(.secondary)
                            Spacer()
                            Text(value).font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
        }
        .navigationTitle("デバイス設定")
        .onAppear {
            scanner.onConnected = { setupState = .enterWiFi }
            scanner.onWiFiConfigured = { setupState = .done }
            scanner.onError = { msg in setupState = .error(msg) }
            scanner.startScan()
        }
        .onDisappear { scanner.stopScan() }
    }

    private var scanningView: some View {
        Group {
            if scanner.discoveredDevices.isEmpty {
                HStack {
                    ProgressView().padding(.trailing, 8)
                    Text("Koe Deviceを探しています...")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(scanner.discoveredDevices, id: \.identifier) { device in
                    Button {
                        selectedDevice = device
                        setupState = .connecting
                        scanner.connect(device)
                    } label: {
                        HStack {
                            Image(systemName: "wave.3.right")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text(device.name ?? "Koe Device")
                                    .font(.headline)
                                Text(device.identifier.uuidString.prefix(8))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("RSSI \(scanner.rssiMap[device.identifier] ?? 0)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var wifiInputView: some View {
        Group {
            // 現在のSSIDを自動入力ヒント
            HStack {
                Image(systemName: "wifi")
                    .foregroundColor(.blue)
                TextField("WiFi SSID", text: $ssid)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .onAppear { fetchCurrentSSID() }
                if !ssid.isEmpty {
                    Button { ssid = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Image(systemName: "lock")
                    .foregroundColor(.orange)
                if showPasswordField {
                    TextField("WiFiパスワード", text: $password)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                } else {
                    SecureField("WiFiパスワード", text: $password)
                        .textContentType(.password)
                }
                Button { showPasswordField.toggle() } label: {
                    Image(systemName: showPasswordField ? "eye.slash" : "eye")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                guard !ssid.isEmpty else { return }
                setupState = .sending
                scanner.sendWiFiConfig(ssid: ssid, password: password)
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "paperplane.fill")
                    Text("WiFi設定を送信")
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .disabled(ssid.isEmpty)
            .tint(.blue)
        }
    }

    private func fetchCurrentSSID() {
        // iOS: NEHotspotNetwork で現在のSSIDを取得
        if #available(iOS 14.0, *) {
            NEHotspotNetwork.fetchCurrent { network in
                if let ssidName = network?.ssid, self.ssid.isEmpty {
                    DispatchQueue.main.async { self.ssid = ssidName }
                }
            }
        }
    }
}

// MARK: - BLE Scanner & Manager

class BLEDeviceScanner: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var rssiMap: [UUID: Int] = [:]
    @Published var connectedDeviceInfo: [(key: String, value: String)] = []

    var onConnected: (() -> Void)?
    var onWiFiConfigured: (() -> Void)?
    var onError: ((String) -> Void)?

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var wifiSSIDChar: CBCharacteristic?
    private var wifiPassChar: CBCharacteristic?
    private var wifiStatusChar: CBCharacteristic?

    // Koe Device BLE Service UUID
    private let koeServiceUUID = CBUUID(string: "FFE0")
    private let wifiSSIDUUID = CBUUID(string: "FFE1")
    private let wifiPassUUID = CBUUID(string: "FFE2")
    private let wifiStatusUUID = CBUUID(string: "FFE3")
    private let deviceInfoUUID = CBUUID(string: "FFE4")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        discoveredDevices = []
        rssiMap = [:]
        if central.state == .poweredOn {
            // サービスUUIDフィルタなしでスキャン（ESP32のGATTサービス登録前でも発見可能）
            // "Koe" を名前に含むデバイスのみ表示
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func sendWiFiConfig(ssid: String, password: String) {
        guard let peripheral = connectedPeripheral else {
            onError?("デバイスが切断されました")
            return
        }

        if let ssidChar = wifiSSIDChar, let passChar = wifiPassChar {
            // GATTサービスが登録されている場合: 個別のcharacteristicsに書き込み
            if let data = ssid.data(using: .utf8) {
                peripheral.writeValue(data, for: ssidChar, type: .withResponse)
            }
            if let data = password.data(using: .utf8) {
                peripheral.writeValue(data, for: passChar, type: .withResponse)
            }
        } else {
            // GATTサービスが未登録の場合: 全サービスの最初のwritable characteristicに JSON送信
            let json = "{\"ssid\":\"\(ssid)\",\"pass\":\"\(password)\"}"
            if let data = json.data(using: .utf8) {
                // 全characteristicsを探してwritableなものに書き込み
                for service in peripheral.services ?? [] {
                    for char in service.characteristics ?? [] {
                        if char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse) {
                            peripheral.writeValue(data, for: char, type: char.properties.contains(.write) ? .withResponse : .withoutResponse)
                            print("[BLE] Wrote WiFi config to \(char.uuid)")
                            // 成功と仮定
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                self.onWiFiConfigured?()
                            }
                            return
                        }
                    }
                }
                // writable characteristicが見つからない
                onError?("デバイスにWiFi設定を書き込めませんでした。ファームウェアを更新してください。")
            }
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScan()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // "Koe" を名前に含むデバイスのみ
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().contains("koe") else { return }
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
        rssiMap[peripheral.identifier] = RSSI.intValue
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // まず全サービスを探索（FFE0が未登録の場合もあるため）
        peripheral.discoverServices(nil)
        // 3秒以内にサービスが見つからなければ接続成功として扱う
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.wifiSSIDChar == nil {
                self?.onConnected?()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onError?("接続に失敗しました: \(error?.localizedDescription ?? "不明")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if error != nil {
            onError?("デバイスが切断されました")
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == koeServiceUUID {
            peripheral.discoverCharacteristics([wifiSSIDUUID, wifiPassUUID, wifiStatusUUID, deviceInfoUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            switch char.uuid {
            case wifiSSIDUUID: wifiSSIDChar = char
            case wifiPassUUID: wifiPassChar = char
            case wifiStatusUUID:
                wifiStatusChar = char
                peripheral.setNotifyValue(true, for: char)
            case deviceInfoUUID:
                peripheral.readValue(for: char)
            default: break
            }
        }
        onConnected?()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == wifiStatusUUID {
            if let status = String(data: data, encoding: .utf8) {
                if status.contains("OK") || status.contains("connected") {
                    DispatchQueue.main.async { self.onWiFiConfigured?() }
                } else if status.contains("FAIL") || status.contains("error") {
                    DispatchQueue.main.async { self.onError?("WiFi接続に失敗: \(status)") }
                }
            }
        } else if characteristic.uuid == deviceInfoUUID {
            if let info = String(data: data, encoding: .utf8) {
                // "key1=val1;key2=val2" format
                let pairs = info.split(separator: ";").compactMap { part -> (key: String, value: String)? in
                    let kv = part.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2 else { return nil }
                    return (key: String(kv[0]), value: String(kv[1]))
                }
                DispatchQueue.main.async { self.connectedDeviceInfo = pairs }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onError?("書き込みエラー: \(error.localizedDescription)")
        }
    }
}
