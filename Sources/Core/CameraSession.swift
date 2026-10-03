import Foundation
import Network

// 每条连接只有一个接收循环，所有协议状态都交由 CameraSession actor 管理。
final class NetworkChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "cn.local.WiFiSync.network.\(UUID())")
    private var ready: CheckedContinuation<Void, Error>?
    var onData: (@Sendable (Data) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    init(host: String, port: UInt16, udp: Bool) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: udp ? .udp : .tcp)
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.ready = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.ready?.resume(); self.ready = nil
                    case .failed(let error):
                        self.ready?.resume(throwing: error); self.ready = nil; self.onFailure?(error.localizedDescription)
                    case .cancelled:
                        self.ready?.resume(throwing: CancellationError()); self.ready = nil
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 10) {
                    if let pending = self.ready {
                        self.ready = nil; pending.resume(throwing: SyncError.message("网络连接超时，请检查相机热点和本地网络权限"))
                        self.connection.cancel()
                    }
                }
            }
        }
    }
    func receiveMessages() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.onData?(data) }
            if let error { self.onFailure?(error.localizedDescription) } else { self.receiveMessages() }
        }
    }
    func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error { self?.onFailure?(error.localizedDescription) }
        })
    }
    func close() { connection.cancel() }
}

actor CameraSession {
    private var channel: NetworkChannel?
    private var sequence = DatalinkSequencer()
    private var decoder = FrameDecoder()
    private var dumlSequence: UInt16 = 0xa000
    private var replies: [DUMLFrame] = []
    private var collectors: [UInt16: ManifestCollector] = [:]
    private var collectorErrors: [UInt16: Error] = [:]
    private var counter: UInt16 = 0
    private var handshaken = false
    private var playback = false
    private var receiving = false
    private var scanning = false
    private var heartbeat: Task<Void, Never>?
    private var lastReceived = Date()
    private var lastPresence = Date.distantPast
    private var registeredAt = Date.distantPast
    private var pairingIdentifier = ""
    private var storageCapacity: [CameraStorage: UInt32] = [:]
    private var generation = UUID()
    let log: @Sendable (String) -> Void
    let disconnected: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void = { _ in }, disconnected: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log; self.disconnected = disconnected
    }

    func open(identifier: String) async throws -> String {
        await close()
        guard ConnectionPreflight.cameraSubnetAvailable else {
            throw SyncError.message("Mac 尚未接入相机热点，请先在系统 WiFi 菜单连接应用显示的热点，再读取素材")
        }
        sequence = DatalinkSequencer(); decoder = FrameDecoder(); replies = []; handshaken = false; playback = false
        generation = UUID(); let token = generation
        pairingIdentifier = identifier; storageCapacity = [:]
        let poke = NetworkChannel(host: "192.168.2.1", port: 7001, udp: false)
        do {
            try await poke.start()
            poke.send(DUMLFrame(receiver: 7, commandSet: 7, command: 0x45,
                                payload: DUMLFrame.packString(identifier) + DUMLFrame.packString("osmo")).encoded())
            try await Task.sleep(for: .milliseconds(400))
        } catch { log("TCP 准备未完成，将继续尝试媒体握手") }
        poke.close()
        let connection = NetworkChannel(host: "192.168.2.1", port: 9004, udp: true)
        channel = connection; receiving = true; lastReceived = Date()
        connection.onData = { [weak self] data in Task { await self?.ingest(data, token: token) } }
        connection.onFailure = { [weak self] message in Task { await self?.fail(message, token: token) } }
        do {
            try await connection.start(); connection.receiveMessages()
            var hello = Data.hex("000064006400c005140000640000019001c005140000640014006400c00514000064000101040102")
            hello.put16(sequence.base, at: 0)
            for _ in 0..<20 {
                try Task.checkCancellation()
                connection.send(sequence.raw(type: 0, payload: hello))
                try await Task.sleep(for: .milliseconds(350))
                if handshaken { break }
            }
            guard handshaken else { throw SyncError.message("相机媒体握手无响应。请连接相机 WiFi，允许本地网络访问，并退出 DJI Mimo 后重试") }
            for _ in 0..<5 { connection.send(sequence.ack()); try await Task.sleep(for: .milliseconds(400)) }
            sequence.sequence = (sequence.peerChannel == 0 ? sequence.base : sequence.peerChannel) &+ 8
            send(set: 0, command: 0x81, receiver: 0x48, flags: 0x80, payload: CameraCommands.deviceInfo)
            try await Task.sleep(for: .milliseconds(400))
            send(set: 0, command: 0x88, receiver: 0x28, payload: CameraCommands.presence)
            try await Task.sleep(for: .milliseconds(400))
            send(set: 3, command: 0xda, receiver: 3, payload: Data.hex("05ffffffff"))
            try await Task.sleep(for: .milliseconds(400))
            registeredAt = Date()
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !Task.isCancelled { await self?.tick(token: token) }
                }
            }
            for _ in 0..<3 {
                send(set: 2, command: 0x0c, payload: Data.hex("01010001"))
                for _ in 0..<9 {
                    try await Task.sleep(for: .milliseconds(100))
                    if playback { break }
                }
                if playback { break }
            }
            guard playback else { throw SyncError.message("相机未确认进入素材回放模式，请停止录制后重新连接") }
            // 相机确认回放后，给存储挂载留出时间。
            try await Task.sleep(for: .milliseconds(1700))
            let versionID = send(set: 0, command: 0, receiver: 0x48, flags: 0x80)
            try await Task.sleep(for: .milliseconds(700))
            let response = replies.last { $0.sequence == versionID && $0.commandSet == 0 && $0.command == 0 }
            let text = response.map { String(decoding: $0.payload, as: UTF8.self) } ?? ""
            let firmware = text.range(of: "[0-9]{2}\\.[0-9]{2}\\.[0-9]{2}\\.[0-9]{2}", options: .regularExpression).map { String(text[$0]) }
            log("媒体会话已建立，固件：\(firmware ?? "未返回（可在相机设置中查看）")")
            return firmware ?? "未返回"
        } catch { await close(); throw error }
    }

    @discardableResult
    private func send(set: UInt8, command: UInt8, receiver: UInt8 = 1, flags: UInt8 = 0x40, payload: Data = Data()) -> UInt16 {
        let id = dumlSequence; dumlSequence &+= 1
        let frame = DUMLFrame(receiver: receiver, sequence: id, flags: flags, commandSet: set, command: command, payload: payload)
        channel?.send(sequence.command(frame)); return id
    }
    private func ingest(_ packet: Data, token: UUID) {
        guard token == generation, receiving, sequence.ingest(packet) else { return }
        lastReceived = Date()
        if packet[6] == 0 { handshaken = true; return }
        if packet.count == 34, packet[6] == 1 { channel?.send(sequence.ack()); return }
        guard packet.count > 20 else { return }
        for frame in decoder.feed(Data(packet.dropFirst(20))) {
            if frame.commandSet == 2, frame.command == 0x80, frame.payload.count >= 4 {
                playback = frame.payload.u32(0) & 0x40000000 != 0
            }
            if frame.commandSet == 2, frame.command == 0xdc, frame.payload.count >= 32 {
                storageCapacity[.sd] = frame.payload.u32(6)
                storageCapacity[.internalMemory] = frame.payload.u32(24)
            }
            if frame.flags & 0xc0 == 0x40 {
                var ack = frame.acknowledgement
                if frame.commandSet == 0, frame.command == 0x81 { ack.payload = CameraCommands.deviceInfo }
                channel?.send(sequence.command(ack))
            }
            if frame.commandSet == 0, frame.command == 0x27, frame.payload.count >= 10 {
                let key = frame.payload.u16(4)
                if var collector = collectors[key] {
                    do { try collector.receive(frame); collectors[key] = collector } catch { collectorErrors[key] = error }
                }
            } else if !frame.payload.isEmpty {
                replies.append(frame); if replies.count > 100 { replies.removeFirst(replies.count - 100) }
            }
        }
        channel?.send(sequence.ack())
    }
    private func tick(token: UUID) {
        guard receiving, token == generation else { return }
        channel?.send(sequence.ack())
        if Date().timeIntervalSince(lastPresence) >= 1 {
            send(set: 0, command: 0x88, receiver: 0x28, payload: CameraCommands.presence); lastPresence = Date()
        }
        if Date().timeIntervalSince(lastReceived) > 15 { fail("相机连接已中断，请重新连接热点并连接素材库", token: token) }
    }
    private func fail(_ message: String, token: UUID) {
        guard token == generation, receiving else { return }
        receiving = false; heartbeat?.cancel(); channel?.close(); disconnected(message)
    }

    private func query(cursor: UInt32, group: Bool = false) async throws -> Data {
        guard receiving, playback else { throw SyncError.message("相机会话不可用，请重新连接") }
        // 长会话可能停止接受分页/组展开请求，主动重新注册恢复写入窗口。
        if Date().timeIntervalSince(registeredAt) > 35 {
            log("刷新媒体会话，继续读取素材")
            _ = try await open(identifier: pairingIdentifier)
        }
        counter &+= 1; if counter == 0 { counter = 1 }
        let key = counter
        collectors[key] = ManifestCollector(counter: key); collectorErrors[key] = nil
        defer { collectors[key] = nil; collectorErrors[key] = nil }
        send(set: 0, command: 0x26, payload: CameraCommands.list(counter: key, cursor: cursor, group: group))
        // 释放查询触发流式传输；计数器必须与该次查询一致。
        try await Task.sleep(for: .milliseconds(800))
        send(set: 0, command: 0x26, payload: CameraCommands.trigger(counter: key))
        for _ in 0..<100 {
            try Task.checkCancellation()
            guard receiving else { throw SyncError.message("素材列表读取中断，请重新连接") }
            if let error = collectorErrors[key] { throw error }
            if let collector = collectors[key], collector.ended { return try collector.manifest() }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SyncError.message("素材列表接收超时，未确认完整性，请重试")
    }
    func listAll(cameraID: String, onPage: @escaping @Sendable ([MediaItem]) -> Void) async throws -> [MediaItem] {
        guard !scanning else { throw SyncError.message("正在读取素材列表") }
        scanning = true; defer { scanning = false }
        var all: [String: MediaItem] = [:]
        var failures: [String] = []
        for storage in CameraStorage.allCases {
            if storage == .sd, storageCapacity[.sd] == 0 {
                log("相机报告没有可用 SD 卡，继续读取内置存储")
                continue
            }
            do {
            var cursor = storage.newestCursor, newest = true
            var previousPages = Set<UInt32>()
            while true {
                try Task.checkCancellation()
                var page: ManifestPage?
                var lastError: Error?
                for attempt in 0..<3 {
                    do {
                        let blob = try await query(cursor: cursor)
                        page = try ManifestParser.decode(blob, cameraID: cameraID, storage: storage); break
                    } catch {
                        if error is CancellationError { throw error }
                        lastError = error; log("\(storage.title)列表读取重试 \(attempt + 1)/3")
                    }
                }
                guard let page else { throw lastError ?? SyncError.message("素材列表读取失败") }
                for item in page.items { all[item.id] = item }
                onPage(Array(all.values))
                log("\(storage.title)本页 \(page.items.count) 项，累计 \(all.count) 项")
                guard let next = try page.nextCursor(previous: cursor, newest: newest) else { break }
                guard previousPages.insert(next).inserted else { throw SyncError.message("相机重复返回同一素材页，拒绝标记扫描完成") }
                cursor = next; newest = false
            }
            } catch {
                if error is CancellationError { throw error }
                failures.append("\(storage.title)：\(error.localizedDescription)")
                log("\(storage.title)扫描未完成，将尝试另一存储")
            }
        }
        for item in Array(all.values) where item.groupBase != nil {
            guard let base = item.groupBase, item.handle != 0 else { throw SyncError.message("照片组句柄不可用，无法保证全部新增素材完整") }
            let expanded = try ManifestParser.decode(try await query(cursor: item.handle, group: true), cameraID: cameraID, storage: item.storage)
            let members = expanded.items.filter { $0.groupBase == base }
            guard !members.isEmpty, expanded.lastPage || members.count < 255 else {
                throw SyncError.message("照片组未完整展开，无法同步全部新增")
            }
            for member in members { all[member.id] = member }
            onPage(Array(all.values))
        }
        if !failures.isEmpty { throw SyncError.message("部分存储尚未完整扫描：" + failures.joined(separator: "；")) }
        return Array(all.values)
    }
    var isReady: Bool { receiving && playback }
    func close() async {
        heartbeat?.cancel(); heartbeat = nil
        if playback { send(set: 2, command: 0x0c, payload: Data.hex("01010000")); try? await Task.sleep(for: .milliseconds(100)) }
        receiving = false; playback = false; channel?.close(); channel = nil; generation = UUID()
    }
}
