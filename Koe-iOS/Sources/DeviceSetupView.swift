import SwiftUI
import CoreBluetooth

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
            TextField("WiFi SSID", text: $ssid)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("WiFiパスワード", text: $password)
                .textContentType(.password)
            Button {
                guard !ssid.isEmpty else { return }
                setupState = .sending
                scanner.sendWiFiConfig(ssid: ssid, password: password)
            } label: {
                HStack {
                    Spacer()
                    Text("接続")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(ssid.isEmpty)
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
            central.scanForPeripherals(withServices: [koeServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
        guard let ssidChar = wifiSSIDChar, let passChar = wifiPassChar,
              let peripheral = connectedPeripheral else {
            onError?("デバイスが切断されました")
            return
        }
        // SSID送信
        if let data = ssid.data(using: .utf8) {
            peripheral.writeValue(data, for: ssidChar, type: .withResponse)
        }
        // パスワード送信
        if let data = password.data(using: .utf8) {
            peripheral.writeValue(data, for: passChar, type: .withResponse)
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
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
        rssiMap[peripheral.identifier] = RSSI.intValue
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([koeServiceUUID])
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
