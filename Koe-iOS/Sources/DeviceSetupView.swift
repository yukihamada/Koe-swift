import SwiftUI
import CoreBluetooth
import NetworkExtension

/// Koe DeviceのBLEセットアップ画面
struct DeviceSetupView: View {
    @StateObject private var scanner = BLEDeviceScanner()
    @State private var ssid = ""
    @State private var password = ""
    @State private var showPassword = false

    var body: some View {
        List {
            // デバイス検出
            Section {
                if !scanner.isConnected {
                    if scanner.discoveredDevices.isEmpty {
                        HStack {
                            ProgressView().padding(.trailing, 8)
                            Text("Koe Deviceを探しています...")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(scanner.discoveredDevices, id: \.identifier) { device in
                            Button {
                                scanner.connect(device)
                            } label: {
                                HStack {
                                    Image(systemName: "wave.3.right")
                                        .foregroundColor(.blue)
                                    Text(device.name ?? "Koe Device")
                                        .font(.headline)
                                    Spacer()
                                    if scanner.connectingDevice?.identifier == device.identifier {
                                        ProgressView().scaleEffect(0.7)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Label("接続済み: \(scanner.connectedPeripheral?.name ?? "Koe Device")", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            } header: {
                Text("デバイス")
            } footer: {
                if !scanner.isConnected {
                    Text("ESP32のLEDが点滅していることを確認してください")
                }
            }

            // WiFi設定（接続後に表示）
            if scanner.isConnected {
                Section {
                    HStack {
                        Image(systemName: "wifi").foregroundColor(.blue)
                        TextField("WiFi SSID", text: $ssid)
                            .autocorrectionDisabled()
                            .onAppear { fetchCurrentSSID() }
                    }

                    HStack {
                        Image(systemName: "lock").foregroundColor(.orange)
                        if showPassword {
                            TextField("パスワード", text: $password)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("パスワード", text: $password)
                        }
                        Button { showPassword.toggle() } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }

                    Button {
                        scanner.sendWiFiConfig(ssid: ssid, password: password)
                    } label: {
                        HStack {
                            Spacer()
                            if scanner.isSending {
                                ProgressView().scaleEffect(0.7).padding(.trailing, 4)
                                Text("送信中...")
                            } else {
                                Image(systemName: "paperplane.fill")
                                Text("WiFi設定を送信")
                            }
                            Spacer()
                        }
                        .fontWeight(.semibold)
                        .padding(.vertical, 4)
                    }
                    .disabled(ssid.isEmpty || scanner.isSending)
                } header: {
                    Text("WiFi設定")
                } footer: {
                    Text("iPhoneが接続中のWiFiと同じネットワークを設定してください")
                }
            }

            // ステータス
            if let status = scanner.statusMessage {
                Section {
                    HStack {
                        Image(systemName: scanner.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(scanner.isSuccess ? .green : .red)
                        Text(status)
                    }
                }
            }

            // エラー
            if let error = scanner.errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Button("再スキャン") {
                            scanner.reset()
                        }
                    }
                }
            }
        }
        .navigationTitle("Koe Device")
        .onAppear { scanner.startScan() }
        .onDisappear { scanner.stopScan() }
    }

    private func fetchCurrentSSID() {
        if #available(iOS 14.0, *) {
            NEHotspotNetwork.fetchCurrent { network in
                if let name = network?.ssid, ssid.isEmpty {
                    DispatchQueue.main.async { ssid = name }
                }
            }
        }
    }
}

// MARK: - BLE Scanner

class BLEDeviceScanner: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var isConnected = false
    @Published var isSending = false
    @Published var isSuccess = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var connectingDevice: CBPeripheral?
    @Published var connectedDeviceInfo: [(key: String, value: String)] = []

    var connectedPeripheral: CBPeripheral?
    private var central: CBCentralManager!
    private var wifiSSIDChar: CBCharacteristic?
    private var wifiPassChar: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        discoveredDevices = []
        errorMessage = nil
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func stopScan() { central.stopScan() }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        connectingDevice = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        // 5秒タイムアウト
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.isConnected, self.connectingDevice != nil else { return }
            self.central.cancelPeripheralConnection(peripheral)
            self.errorMessage = "接続タイムアウト"
            self.connectingDevice = nil
        }
    }

    func sendWiFiConfig(ssid: String, password: String) {
        guard let peripheral = connectedPeripheral else {
            errorMessage = "デバイスが切断されました"
            return
        }
        isSending = true
        statusMessage = "WiFi設定を送信中..."

        if let ssidChar = wifiSSIDChar, let passChar = wifiPassChar {
            if let d = ssid.data(using: .utf8) { peripheral.writeValue(d, for: ssidChar, type: .withResponse) }
            if let d = password.data(using: .utf8) { peripheral.writeValue(d, for: passChar, type: .withResponse) }
        } else {
            // GATTサービス未登録: JSONで全characteristicsに書き込み試行
            let json = "{\"ssid\":\"\(ssid)\",\"pass\":\"\(password)\"}"
            if let data = json.data(using: .utf8) {
                var wrote = false
                for service in peripheral.services ?? [] {
                    for char in service.characteristics ?? [] where char.properties.contains(.write) {
                        peripheral.writeValue(data, for: char, type: .withResponse)
                        wrote = true
                        break
                    }
                    if wrote { break }
                }
            }
        }

        // 3秒後に成功と仮定（ESP32が再起動するため応答がない場合）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.isSending = false
            self?.isSuccess = true
            self?.statusMessage = "WiFi設定を送信しました。デバイスが再起動します。"
        }
    }

    func reset() {
        isConnected = false
        isSending = false
        isSuccess = false
        statusMessage = nil
        errorMessage = nil
        connectingDevice = nil
        connectedPeripheral = nil
        wifiSSIDChar = nil
        wifiPassChar = nil
        startScan()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().contains("koe") else { return }
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        connectingDevice = nil
        isConnected = true
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectingDevice = nil
        errorMessage = "接続失敗: \(error?.localizedDescription ?? "不明")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !isSuccess { // 成功時の切断は正常（ESP32再起動）
            isConnected = false
            connectedPeripheral = nil
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let ssidUUID = CBUUID(string: "FFE1")
        let passUUID = CBUUID(string: "FFE2")
        for char in service.characteristics ?? [] {
            if char.uuid == ssidUUID { wifiSSIDChar = char }
            if char.uuid == passUUID { wifiPassChar = char }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.errorMessage = "書き込みエラー: \(error.localizedDescription)" }
        }
    }
}
