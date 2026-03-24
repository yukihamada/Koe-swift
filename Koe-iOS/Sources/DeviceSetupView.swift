import SwiftUI
import CoreBluetooth
import NetworkExtension

struct DeviceSetupView: View {
    @StateObject private var scanner = BLEDeviceScanner()
    @StateObject private var bridge = BLEAudioBridge()
    @State private var ssid = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var deviceName = "Koe Device"
    @Environment(\.dismiss) private var dismiss

    @State private var showWifiSetup = false

    var body: some View {
        Group {
            if scanner.setupComplete {
                setupCompleteView
            } else if showWifiSetup {
                setupFormView
            } else {
                simpleConnectView
            }
        }
        .navigationTitle(scanner.setupComplete ? "" : "Koe Device")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { scanner.startScan() }
        .onDisappear { scanner.stopScan() }
    }

    // MARK: - シンプル接続画面（タップ1回）

    private var simpleConnectView: some View {
        VStack(spacing: 24) {
            Spacer()

            // デバイスアニメーション
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.2), lineWidth: 2)
                    .frame(width: 160, height: 160)
                Circle()
                    .stroke(Color.blue.opacity(0.1), lineWidth: 1)
                    .frame(width: 200, height: 200)
                    .scaleEffect(scanner.isScanning ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: scanner.isScanning)

                if let device = scanner.discoveredDevices.first {
                    // デバイス見つかった
                    Button {
                        deviceName = device.name ?? "Koe Device"
                        scanner.connect(device)
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle().fill(.blue).frame(width: 80, height: 80)
                                Image(systemName: "wave.3.right")
                                    .font(.system(size: 32))
                                    .foregroundColor(.white)
                            }
                            Text(device.name ?? "Koe Device")
                                .font(.headline)
                            if scanner.connectingDevice != nil {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Text("タップして接続")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .disabled(scanner.connectingDevice != nil)
                } else {
                    // スキャン中
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .frame(width: 80, height: 80)
                        Text("デバイスを探しています...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if scanner.isConnected {
                // 接続成功 → iPhone経由ブリッジモード
                VStack(spacing: 12) {
                    Label("Bluetooth接続完了", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.headline)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(bridge.isActive ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(bridge.isActive ? bridge.statusText : "ブリッジ起動中...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onAppear {
                    // ブリッジ起動してから完了画面へ
                    if let p = scanner.connectedPeripheral {
                        bridge.start(peripheral: p, chars: scanner.allDiscoveredCharacteristics, scanner: scanner)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        scanner.setupComplete = true
                    }
                }
            }

            Spacer()

            // 下部: WiFi直接設定オプション
            Button {
                showWifiSetup = true
            } label: {
                Text("WiFiに直接接続する（上級者向け）")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 20)

            if let error = scanner.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - セットアップ完了画面

    private var setupCompleteView: some View {
        VStack(spacing: 0) {
            Spacer()

            // 🎉 アニメーション
            VStack(spacing: 20) {
                Text("🎉")
                    .font(.system(size: 80))
                    .scaleEffect(scanner.celebrationScale)
                    .animation(.spring(response: 0.5, dampingFraction: 0.4).delay(0.2), value: scanner.celebrationScale)

                Text("セットアップ完了！")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
                    )

                Text("\(deviceName) にWiFi設定を送信しました")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // デバイス情報カード
                VStack(spacing: 12) {
                    infoRow(icon: "wifi", label: "WiFi", value: ssid)
                    infoRow(icon: "wave.3.right", label: "デバイス", value: deviceName)
                    infoRow(icon: "arrow.clockwise", label: "ステータス", value: "WiFi接続中（再起動中）")
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(16)
                .padding(.horizontal)
            }

            Spacer()

            // 次のアクション
            VStack(spacing: 12) {
                Text("次にできること")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 16) {
                    actionCard(icon: "mic.fill", title: "音声入力", color: .red)
                    actionCard(icon: "doc.text", title: "議事録", color: .blue)
                    actionCard(icon: "music.note", title: "Soluna", color: .purple)
                }
                .padding(.horizontal)
            }

            Spacer().frame(height: 40)

            Button {
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("使い始める →")
                        .font(.headline)
                    Spacer()
                }
                .padding()
                .background(
                    LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
                )
                .foregroundColor(.white)
                .cornerRadius(14)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .onAppear {
            // セレブレーションアニメーション開始
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                scanner.celebrationScale = 1.0
            }
            // ハプティクスフィードバック
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
    }

    // MARK: - セットアップフォーム

    private var setupFormView: some View {
        List {
            // Step 1: デバイス接続
            Section {
                if !scanner.isConnected {
                    if scanner.discoveredDevices.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading) {
                                Text("Koe Deviceを探しています...")
                                Text("LEDが点滅していることを確認")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        ForEach(scanner.discoveredDevices, id: \.identifier) { device in
                            Button {
                                deviceName = device.name ?? "Koe Device"
                                scanner.connect(device)
                            } label: {
                                HStack {
                                    ZStack {
                                        Circle().fill(.blue.opacity(0.15)).frame(width: 40, height: 40)
                                        Image(systemName: "wave.3.right").foregroundColor(.blue)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name ?? "Koe Device").font(.headline)
                                        Text("タップして接続").font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if scanner.connectingDevice?.identifier == device.identifier {
                                        ProgressView().scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    HStack {
                        ZStack {
                            Circle().fill(.blue.opacity(0.15)).frame(width: 40, height: 40)
                            Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(.blue)
                        }
                        VStack(alignment: .leading) {
                            Text(deviceName).font(.headline)
                            Text("Bluetooth接続済み — 次にWiFiを設定してください").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Label("Step 1: Bluetooth接続", systemImage: scanner.isConnected ? "checkmark.circle.fill" : "1.circle.fill")
                    .foregroundColor(scanner.isConnected ? .blue : .primary)
            }

            // Step 2: WiFi設定（接続後に表示）
            if scanner.isConnected {
                Section {
                    // iPhoneテザリングボタン
                    Button {
                        useHotspot()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(.green.opacity(0.15)).frame(width: 36, height: 36)
                                Image(systemName: "iphone.radiowaves.left.and.right").foregroundColor(.green)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iPhoneのテザリングを使う")
                                    .font(.subheadline).fontWeight(.medium)
                                Text("このiPhoneのインターネット共有に自動接続")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(.secondary).font(.caption)
                        }
                    }

                    // 区切り
                    HStack {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5)
                        Text("または").font(.caption2).foregroundColor(.secondary)
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5)
                    }

                    // 手動WiFi入力
                    HStack(spacing: 12) {
                        Image(systemName: "wifi").foregroundColor(.blue).frame(width: 20)
                        TextField("WiFi SSID (ネットワーク名)", text: $ssid)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onAppear { fetchCurrentSSID() }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "lock").foregroundColor(.orange).frame(width: 20)
                        if showPassword {
                            TextField("パスワード", text: $password)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
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
                    Label("Step 2: インターネット接続", systemImage: "2.circle.fill")
                } footer: {
                    Text("テザリングまたはWiFiでインターネットに接続します")
                }
            }

            // エラー表示
            if let error = scanner.errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.callout)
                        Button("再スキャン") { scanner.reset() }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(.orange).frame(width: 24)
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private func actionCard(icon: String, title: String, color: Color) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.1)).frame(height: 70)
                Image(systemName: icon).font(.title).foregroundColor(color)
            }
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func useHotspot() {
        // iPhoneのテザリング: デバイス名がSSIDになる
        let iphoneName = UIDevice.current.name
        ssid = iphoneName
        password = ""
        // テザリングのパスワードは自動取得できないので入力を求める
        // ただしSSIDは自動設定
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
    @Published var isScanning = false
    @Published var isSending = false
    @Published var setupComplete = false
    @Published var celebrationScale: CGFloat = 0.3
    @Published var errorMessage: String?
    @Published var connectingDevice: CBPeripheral?

    var connectedPeripheral: CBPeripheral?
    var allDiscoveredCharacteristics: [CBCharacteristic] = []
    var onAudioChunkReceived: ((Data) -> Void)?  // ブリッジへの転送用
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
        isScanning = true
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func stopScan() { central.stopScan(); isScanning = false }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        connectingDevice = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.isConnected, self.connectingDevice != nil else { return }
            self.central.cancelPeripheralConnection(peripheral)
            self.errorMessage = "接続タイムアウト。デバイスが近くにあることを確認してください。"
            self.connectingDevice = nil
        }
    }

    func sendWiFiConfig(ssid: String, password: String) {
        guard let peripheral = connectedPeripheral else {
            errorMessage = "デバイスが切断されました"
            return
        }
        isSending = true

        if let ssidChar = wifiSSIDChar, let passChar = wifiPassChar {
            if let d = ssid.data(using: .utf8) { peripheral.writeValue(d, for: ssidChar, type: .withResponse) }
            if let d = password.data(using: .utf8) { peripheral.writeValue(d, for: passChar, type: .withResponse) }
        } else {
            let json = "{\"ssid\":\"\(ssid)\",\"pass\":\"\(password)\"}"
            if let data = json.data(using: .utf8) {
                for service in peripheral.services ?? [] {
                    for char in service.characteristics ?? [] where char.properties.contains(.write) {
                        peripheral.writeValue(data, for: char, type: .withResponse)
                        break
                    }
                }
            }
        }

        // ESP32が再起動するため応答がない → 3秒後にセットアップ完了画面に遷移
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.isSending = false
            self?.setupComplete = true
        }
    }

    func reset() {
        isConnected = false
        isSending = false
        setupComplete = false
        celebrationScale = 0.3
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
        // ハプティクス
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectingDevice = nil
        errorMessage = "接続失敗: \(error?.localizedDescription ?? "不明なエラー")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if !setupComplete { isConnected = false; connectedPeripheral = nil }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            if char.uuid == CBUUID(string: "FFE1") { wifiSSIDChar = char }
            if char.uuid == CBUUID(string: "FFE2") { wifiPassChar = char }
            allDiscoveredCharacteristics.append(char)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BLEAudioBridge.audioTXUUID,
              let data = characteristic.value else { return }
        onAudioChunkReceived?(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { DispatchQueue.main.async { self.errorMessage = "書き込みエラー: \(error.localizedDescription)" } }
    }
}
