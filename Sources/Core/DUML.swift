import Foundation

extension Data {
    static func hex(_ string: String) -> Data {
        let chars = Array(string.filter { !$0.isWhitespace })
        return Data(stride(from: 0, to: chars.count - 1, by: 2).compactMap { UInt8(String(chars[$0...($0 + 1)]), radix: 16) })
    }
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
    mutating func put16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value); self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    mutating func put32(_ value: UInt32, at offset: Int) {
        put16(UInt16(truncatingIfNeeded: value), at: offset)
        put16(UInt16(truncatingIfNeeded: value >> 16), at: offset + 2)
    }
}

// DUML 校验及字段布局参考 Osmosis/dji-remote，许可见 THIRD_PARTY_NOTICES.md。
enum DJICRC {
    static func crc8(_ bytes: Data) -> UInt8 {
        var crc: UInt8 = 0x77
        for byte in bytes { crc ^= byte; for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8c : crc >> 1 } }
        return crc
    }
    static func crc16(_ bytes: Data) -> UInt16 {
        var crc: UInt16 = 0x3692
        for byte in bytes { crc ^= UInt16(byte); for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 } }
        return crc
    }
}

struct DUMLFrame: Equatable {
    var sender: UInt8 = 2
    var receiver: UInt8 = 1
    var sequence: UInt16 = 0xa000
    var flags: UInt8 = 0x40
    let commandSet: UInt8
    let command: UInt8
    var payload: Data = Data()

    func encoded() -> Data {
        precondition(payload.count <= 1010)
        let length = UInt16(payload.count + 13) | 0x400
        var bytes = Data(repeating: 0, count: 11)
        bytes[0] = 0x55; bytes.put16(length, at: 1); bytes[3] = DJICRC.crc8(Data(bytes.prefix(3)))
        bytes[4] = sender; bytes[5] = receiver; bytes.put16(sequence, at: 6)
        bytes[8] = flags; bytes[9] = commandSet; bytes[10] = command
        bytes.append(payload)
        let crc = DJICRC.crc16(bytes)
        bytes.append(UInt8(truncatingIfNeeded: crc)); bytes.append(UInt8(truncatingIfNeeded: crc >> 8))
        return bytes
    }
    var acknowledgement: DUMLFrame {
        DUMLFrame(sender: receiver, receiver: sender, sequence: sequence, flags: 0xc0,
                  commandSet: commandSet, command: command, payload: Data([0]))
    }
    static func packString(_ value: String) -> Data {
        let bytes = Data(value.utf8); precondition(bytes.count <= 255)
        return Data([UInt8(bytes.count)]) + bytes
    }
}

struct FrameDecoder {
    private var buffer = Data()
    mutating func feed(_ bytes: Data) -> [DUMLFrame] {
        buffer.append(bytes)
        var frames: [DUMLFrame] = []
        while buffer.count >= 4 {
            guard buffer[0] == 0x55, buffer[2] >> 2 == 1,
                  DJICRC.crc8(Data(buffer.prefix(3))) == buffer[3] else { buffer = Data(buffer.dropFirst()); continue }
            let count = Int(buffer.u16(1) & 0x3ff)
            guard count >= 13 else { buffer = Data(buffer.dropFirst()); continue }
            guard buffer.count >= count else { break }
            let frame = Data(buffer.prefix(count))
            guard DJICRC.crc16(Data(frame.dropLast(2))) == frame.u16(count - 2) else {
                buffer = Data(buffer.dropFirst()); continue
            }
            frames.append(DUMLFrame(sender: frame[4], receiver: frame[5], sequence: frame.u16(6), flags: frame[8],
                                    commandSet: frame[9], command: frame[10], payload: Data(frame[11..<(count - 2)])))
            buffer = Data(buffer.dropFirst(count))
        }
        return frames
    }
}

enum CameraCommands {
    static let presence = Data.hex("170046237c415050000000000002")
    static var deviceInfo: Data {
        var bytes = Data(repeating: 0, count: 62)
        bytes[1] = 65; bytes[2] = 80; bytes[3] = 80; bytes[41] = 2; bytes[50] = 2; bytes[51] = 8
        return bytes
    }
    static func list(counter: UInt16, cursor: UInt32, group: Bool = false) -> Data {
        var bytes = Data.hex("4a002a10010000000000010000002d000d0100ffffffffffffffff000100000000000000000000000000")
        bytes.put16(counter, at: 4); bytes.put32(cursor, at: 10)
        if group { bytes[14] = 255; bytes[16] = 0x10; bytes[39] = 1 }
        return bytes
    }
    static func trigger(counter: UInt16) -> Data {
        var bytes = Data.hex("4a040e1001000000000001000000"); bytes.put16(counter, at: 4); return bytes
    }
}

struct DatalinkSequencer {
    var sessionID: UInt16 = UInt16.random(in: 0x1000..<0xfffe)
    var base: UInt16 = UInt16.random(in: 0x1000..<0xf000) & 0xfff8
    var sequence: UInt16 = 0
    var commandCounter: UInt8 = 0
    var peerChannel: UInt16 = 0
    var videoWindow: UInt16 = 0
    var downloadWindow: UInt16 = 0

    mutating func raw(type: UInt8, payload: Data) -> Data {
        let result = header(type: type, count: payload.count, seq: sequence) + payload
        sequence &+= 8; return result
    }
    func header(type: UInt8, count: Int, seq: UInt16) -> Data {
        var b = Data(repeating: 0, count: 8)
        b.put16(UInt16(count + 8) | 0x8000, at: 0); b.put16(sessionID, at: 2); b.put16(seq, at: 4); b[6] = type
        b[7] = b.prefix(7).reduce(0, ^); return b
    }
    mutating func command(_ frame: DUMLFrame) -> Data {
        commandCounter &+= 1
        var routing = Data(repeating: 0, count: 12)
        routing.put16(sequence &- 8, at: 0); routing.put16(sequence, at: 2)
        routing[8] = commandCounter; routing[9] = 1
        return raw(type: 5, payload: routing + frame.encoded())
    }
    func ack() -> Data {
        var b = Data(repeating: 0, count: 26)
        for (offset, value) in [(0, videoWindow), (8, downloadWindow), (16, base)] {
            b.put16(value, at: offset); b.put16(value, at: offset + 2)
        }
        return header(type: 4, count: b.count, seq: 0) + b
    }
    mutating func ingest(_ packet: Data) -> Bool {
        guard packet.count >= 8, packet.prefix(7).reduce(0, ^) == packet[7],
              Int(packet.u16(0) & 0x3fff) == packet.count, packet.u16(2) == sessionID else { return false }
        if packet.count >= 10, packet.u16(8) != 0 { peerChannel = packet.u16(8) }
        if packet.count == 34, packet[6] == 1 {
            videoWindow = packet.u16(10); downloadWindow = packet.u16(18)
        }
        return true
    }
}
