import Foundation
import CoreBluetooth
import Combine

@MainActor
final class CameraDiscovery: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published private(set) var devices: [CameraDevice] = []
    @Published private(set) var status = "准备扫描相机"
    @Published private(set) var isScanning = false
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var pairingCharacteristic: CBCharacteristic?
    private var notified = Set<String>()
    private var armed = false
    private var failure: Error?
    private var decoder = FrameDecoder()
    private var responses: [DUMLFrame] = []
    private var approved = false
    private var preparing = false
    private var writing = false
    private var sequence: UInt16 = 0x8000
    private var heartbeat: Task<Void, Never>?
    var log: (String) -> Void = { _ in }
    var onDisconnect: (String) -> Void = { _ in }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func startScan() {
        guard central.state == .poweredOn else { status = stateMessage(central.state); return }
        devices = []; peripherals = [:]; isScanning = true; status = "正在寻找 Action 5 Pro，请开机并靠近 Mac"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.stopScan()
            if self?.devices.isEmpty == true { self?.status = "未发现 Action 5 Pro，请检查相机无线连接设置和蓝牙权限" }
        }
    }
    func stopScan() { central.stopScan(); isScanning = false }
    func centralManagerDidUpdateState(_ central: CBCentralManager) { status = stateMessage(central.state) }
    private func stateMessage(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "蓝牙已就绪"
        case .poweredOff: return "请在系统设置中开启蓝牙"
        case .unauthorized: return "蓝牙权限被拒绝，请在系统设置 → 隐私与安全性 → 蓝牙中允许本应用"
        case .unsupported: return "此 Mac 不支持蓝牙连接"
        default: return "正在准备蓝牙"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 4 else { return }
        let company = data.u16(0)
        guard [UInt16(0x08aa), 0xf7aa, 0xe5c0].contains(company) else { return }
        var model = data.u16(2)
        if data.count >= 14, data[7] & 4 != 0, data.u16(12) == 235 { model = 0x15 }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Action 5 Pro"
        // 同型号编号的 Xtra 属于另一种网络协议，首版明确排除。
        guard model == 0x15, !name.lowercased().contains("xtra") else { return }
        peripherals[peripheral.identifier] = peripheral
        let device = CameraDevice(id: peripheral.identifier, name: name, signal: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device } else { devices.append(device) }
    }
    func prepare(_ device: CameraDevice) async throws -> HotspotCredentials {
        guard !preparing else { throw SyncError.message("正在连接相机") }
        guard let p = peripherals[device.id] else { throw SyncError.message("请重新扫描相机") }
        preparing = true; defer { preparing = false }
        disconnect(); stopScan()
        failure = nil; armed = false; approved = false; notified = []; responses = []; decoder = FrameDecoder()
        peripheral = p; p.delegate = self; status = "正在建立蓝牙连接"
        central.connect(p)
        do {
            try await wait(seconds: 15) { self.armed }
            try await Task.sleep(for: .milliseconds(200))
            _ = try await send(set: 0, command: 0x2b, receiver: 0xf0, payload: Data([4, 0]))
            try await Task.sleep(for: .milliseconds(200))
            let paired = try await request(set: 7, command: 0x45, payload: DUMLFrame.packString(CredentialStore.identifier) + DUMLFrame.packString("osmo"))
            guard paired.count >= 2, paired[0] == 0 else { throw SyncError.message("相机拒绝配对，请重新连接") }
            // 配对响应之后即开始保活，用户确认屏幕时也不让蓝牙会话过期。
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { break }
                    do { _ = try await self.send(set: 0, command: 0x2b, receiver: 0xf0, payload: Data([1, 1])) }
                    catch { self.status = "蓝牙会话已中断"; break }
                }
            }
            if paired[1] == 2 {
                status = "请在相机屏幕上确认连接"
                try await wait(seconds: 60) { self.approved }
            } else if paired[1] != 1 { throw SyncError.message("相机返回未知配对状态") }
            status = "正在开启相机无线会话"
            _ = try await send(set: 0, command: 0x2b, receiver: 0xf0, payload: Data([1, 1]))
            try await Task.sleep(for: .milliseconds(200))
            _ = try await send(set: 0x53, command: 0x10, receiver: 0x1c, payload: Data(repeating: 0, count: 4))
            try await Task.sleep(for: .milliseconds(500))
            let ssid = try unpackString(try await request(set: 7, command: 7))
            try await Task.sleep(for: .milliseconds(250))
            let password: String
            do { password = try unpackString(try await request(set: 7, command: 0x0e)) }
            catch {
                guard let saved = CredentialStore.load(cameraID: device.id.uuidString), saved.ssid == ssid else { throw error }
                password = saved.password
            }
            let credentials = HotspotCredentials(ssid: ssid, password: password)
            try CredentialStore.save(credentials, cameraID: device.id.uuidString)
            status = "配对完成，请在系统 WiFi 菜单中连接 \(ssid)"
            log("蓝牙配对完成，热点信息已保存到钥匙串")
            return credentials
        } catch { disconnect(); status = error.localizedDescription; throw error }
    }
    // CoreBluetooth 不提供应用指定 ATT MTU 的接口，使用系统协商结果并按写入上限分片。
    private func write(_ bytes: Data) async throws {
        try await wait(seconds: 5) { !self.writing }
        writing = true; defer { writing = false }
        guard let p = peripheral, p.state == .connected, let ch = commandCharacteristic else { throw SyncError.message("蓝牙连接已断开") }
        let maximum = min(497, p.maximumWriteValueLength(for: .withoutResponse))
        guard maximum > 0 else { throw SyncError.message("蓝牙写入通道不可用") }
        for start in stride(from: 0, to: bytes.count, by: maximum) {
            try await wait(seconds: 5) { p.canSendWriteWithoutResponse }
            p.writeValue(Data(bytes[start..<min(start + maximum, bytes.count)]), for: ch, type: .withoutResponse)
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    @discardableResult
    private func send(set: UInt8, command: UInt8, receiver: UInt8 = 7, payload: Data = Data()) async throws -> UInt16 {
        sequence &+= 1; let id = sequence
        try await write(DUMLFrame(receiver: receiver, sequence: id, commandSet: set, command: command, payload: payload).encoded())
        return id
    }
    private func request(set: UInt8, command: UInt8, payload: Data = Data()) async throws -> Data {
        for _ in 0..<3 {
            let id = try await send(set: set, command: command, payload: payload)
            do {
                try await wait(seconds: 3) { self.responses.contains { $0.sequence == id && $0.commandSet == set && $0.command == command && !$0.payload.isEmpty } }
                if let frame = responses.last(where: { $0.sequence == id && $0.commandSet == set && $0.command == command && !$0.payload.isEmpty }) { return frame.payload }
            } catch { if error is CancellationError || failure != nil { throw error } }
        }
        throw SyncError.message("相机蓝牙指令无响应，请退出 DJI Mimo、重新开机后重试")
    }
    private func unpackString(_ payload: Data) throws -> String {
        guard payload.count >= 2, payload[0] == 0, payload.count >= 2 + Int(payload[1]),
              let string = String(data: payload[2..<(2 + Int(payload[1]))], encoding: .utf8), !string.isEmpty else { throw SyncError.message("相机未返回有效热点信息") }
        return string
    }
    private func wait(seconds: Double, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            try Task.checkCancellation()
            if let failure { throw failure }
            guard Date() < deadline else { throw SyncError.message("蓝牙连接或确认超时，请重试") }
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    func disconnect() {
        heartbeat?.cancel(); heartbeat = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil; commandCharacteristic = nil; pairingCharacteristic = nil
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([CBUUID(string: "FFF0")]) }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failure = error ?? SyncError.message("蓝牙连接失败")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        if let error { log("蓝牙系统诊断：\(error.localizedDescription)") }
        failure = SyncError.message("相机蓝牙连接已中断，请重新选择相机配对")
        heartbeat?.cancel(); status = failure!.localizedDescription; onDisconnect(status)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { failure = error; return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "FFF0") }) else { failure = SyncError.message("相机未提供媒体蓝牙服务"); return }
        peripheral.discoverCharacteristics([CBUUID(string: "FFF4"), CBUUID(string: "FFF5")], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { failure = error; return }
        commandCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF5") }
        pairingCharacteristic = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF4") }
        guard let commandCharacteristic, let pairingCharacteristic else { failure = SyncError.message("相机蓝牙通道不完整"); return }
        peripheral.setNotifyValue(true, for: pairingCharacteristic)
        peripheral.setNotifyValue(true, for: commandCharacteristic)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failure = error; return }
        guard characteristic.isNotifying else { return }
        notified.insert(characteristic.uuid.uuidString)
        if notified.count == 2, let arm = pairingCharacteristic { peripheral.writeValue(Data([1, 0]), for: arm, type: .withResponse) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failure = error; return }
        if characteristic.uuid == CBUUID(string: "FFF4") { armed = true }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failure = error; return }
        guard let data = characteristic.value else { return }
        for frame in decoder.feed(data) {
            if frame.flags & 0xc0 == 0x40 {
                Task { try? await self.write(frame.acknowledgement.encoded()) }
            }
            if frame.commandSet == 7, frame.command == 0x46, frame.payload.first == 1 { approved = true }
            responses.append(frame); if responses.count > 100 { responses.removeFirst(responses.count - 100) }
        }
    }
}
