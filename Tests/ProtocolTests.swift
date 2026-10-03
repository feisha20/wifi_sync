import XCTest
@testable import WiFiSyncCore

final class ProtocolTests: XCTestCase {
    func testKnownWireFrame() {
        let frame = DUMLFrame(receiver: 7, sequence: 0xa000, commandSet: 7, command: 7)
        XCTAssertEqual(frame.encoded(), Data.hex("550d0433020700a04007077472"))
    }
    func testSplitLongFrameNoiseAndCorruption() {
        let frame = DUMLFrame(commandSet: 0, command: 0x27, payload: Data(repeating: 0xab, count: 500))
        let bytes = frame.encoded()
        var decoder = FrameDecoder()
        XCTAssertTrue(decoder.feed(Data([0, 1, 2]) + bytes.prefix(123)).isEmpty)
        XCTAssertEqual(decoder.feed(Data(bytes.dropFirst(123))), [frame])
        var broken = bytes; broken[20] ^= 1
        XCTAssertEqual(decoder.feed(broken + bytes), [frame])
    }
    func testRoutingAndWindowAcknowledgements() {
        var sequence = DatalinkSequencer(sessionID: 0x1234, base: 0x8800, sequence: 0)
        let command = sequence.command(DUMLFrame(commandSet: 2, command: 0x0c))
        XCTAssertEqual(command.u16(8), 0xfff8)
        XCTAssertEqual(command.u16(10), 0)
        XCTAssertEqual(sequence.sequence, 8)
        var status = sequence.header(type: 1, count: 26, seq: 0) + Data(repeating: 0, count: 26)
        status.put16(0x8800, at: 8); status.put16(0x8810, at: 10); status.put16(0x8990, at: 18)
        XCTAssertTrue(sequence.ingest(status))
        let ack = sequence.ack()
        XCTAssertEqual(ack.u16(4), 0)
        XCTAssertEqual(ack.u16(8), 0x8810)
        XCTAssertEqual(ack.u16(16), 0x8990)
        XCTAssertEqual(ack.u16(24), 0x8800)
        status[7] ^= 1; XCTAssertFalse(sequence.ingest(status))
    }
    private func chunk(_ number: UInt32, counter: UInt16, type: UInt8 = 1, bytes: Data = Data()) -> DUMLFrame {
        var p = Data(repeating: 0, count: 10); p[0] = 0x4a; p[1] = type
        p.put16(counter, at: 4); p.put32(number, at: 6); p.append(bytes)
        return DUMLFrame(commandSet: 0, command: 0x27, payload: p)
    }
    func testChunkOrderingIsolationAndMissingChunk() throws {
        var collector = ManifestCollector(counter: 2)
        try collector.receive(chunk(1, counter: 2, bytes: Data([3, 4])))
        try collector.receive(chunk(0, counter: 1, bytes: Data([9])))
        try collector.receive(chunk(0, counter: 2, bytes: Data([1, 2])))
        XCTAssertThrowsError(try collector.manifest())
        try collector.receive(chunk(2, counter: 2, type: 3))
        XCTAssertEqual(try collector.manifest(), Data([1, 2, 3, 4]))
        var missing = ManifestCollector(counter: 2)
        try missing.receive(chunk(0, counter: 2, bytes: Data([1])))
        try missing.receive(chunk(2, counter: 2, bytes: Data([3])))
        try missing.receive(chunk(3, counter: 2, type: 3))
        XCTAssertThrowsError(try missing.manifest())
        var lostFirst = ManifestCollector(counter: 2)
        try lostFirst.receive(chunk(1, counter: 2, bytes: Data([2])))
        try lostFirst.receive(chunk(2, counter: 2, type: 3))
        XCTAssertThrowsError(try lostFirst.manifest())
    }
    static func item(number: Int = 1, storage: CameraStorage = .sd, path: String? = nil, size: Int64 = 100) -> MediaItem {
        MediaItem(cameraID: "测试相机", storage: storage, path: path ?? "DCIM/自定义目录/素材_\(number).MP4", thumbnailPath: "MISC/THM/素材_\(number)",
                  handle: UInt32(0x40000 + number * 16) | (storage == .internalMemory ? 0x40000000 : 0), size: size,
                  capturedAt: nil, duration: 2)
    }
    func testStoreIdentityURLAndGroup() throws {
        let sd = Self.item(), internalItem = Self.item(storage: .internalMemory)
        XCTAssertNotEqual(sd.id, internalItem.id)
        let url = try MediaAddress.url(for: internalItem, rendition: .original)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "storage" }?.value, "1")
        XCTAssertEqual(query.first { $0.name == "path" }?.value, internalItem.path)
        XCTAssertEqual(Self.item(path: "DCIM/素材_D_001.JPG").groupBase, "素材_D")
        XCTAssertNil(Self.item(path: "DCIM/素材_D.JPG").groupBase)
    }
    func testPaginationOver45AndRepeatFails() throws {
        let page = ManifestPage(items: (1...45).map { Self.item(number: $0) }, lastPage: false, declaredCount: 0)
        let next = try XCTUnwrap(page.nextCursor(previous: 1, newest: true))
        XCTAssertEqual(next, 0x40010)
        XCTAssertThrowsError(try page.nextCursor(previous: next, newest: false))
        XCTAssertNil(try ManifestPage(items: [Self.item()], lastPage: true, declaredCount: 0).nextCursor(previous: next, newest: false))
    }
    func testPreviewCandidatesPreserveStorageAndPath() throws {
        let item = Self.item(storage: .internalMemory)
        let urls = try MediaAddress.candidates(for: item, rendition: .photoPreview)
        XCTAssertEqual(urls.count, 2)
        let queries = urls.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)!.queryItems! }
        XCTAssertEqual(queries[0].first { $0.name == "path" }?.value, "MISC/THM/素材_1.scr")
        XCTAssertEqual(queries[1].first { $0.name == "path" }?.value, "MISC/THM/素材_1.thm")
        XCTAssertTrue(queries.allSatisfy { $0.first { $0.name == "storage" }?.value == "1" })
        XCTAssertEqual(try MediaAddress.candidates(for: item, rendition: .proxy).count, 1)
        XCTAssertEqual(try MediaAddress.candidates(for: item, rendition: .original), [try MediaAddress.url(for: item, rendition: .original)])
    }
    func testGroupRequestWireShape() {
        let request = CameraCommands.list(counter: 12, cursor: 0x40040010, group: true)
        XCTAssertEqual(request.u16(4), 12)
        XCTAssertEqual(request.u32(10), 0x40040010)
        XCTAssertEqual(request[14], 255); XCTAssertEqual(request[16], 0x10); XCTAssertEqual(request[39], 1)
        XCTAssertEqual(CameraCommands.trigger(counter: 12).u16(4), 12)
    }
    func testFATDateAndInvalidDate() {
        let packed: UInt32 = UInt32((2026 - 1980) << 9 | 10 << 5 | 3) << 16 | UInt32(23 << 11 | 59 << 5 | 29)
        let date = MediaItem.cameraDate(packed)
        XCTAssertNotNil(date)
        let item = MediaItem(cameraID: "a", storage: .sd, path: "DCIM/a.JPG", thumbnailPath: nil, handle: 1, size: 1, capturedAt: date, duration: 0)
        XCTAssertEqual(item.dayFolder, "2026-10-03")
        XCTAssertNil(MediaItem.cameraDate(0))
    }
    func testRealReferenceCompositeManifest() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "xtra_13_manifest", withExtension: "bin", subdirectory: "Fixtures"))
        let page = try ManifestParser.decode(Data(contentsOf: url), cameraID: "参考夹具", storage: .internalMemory)
        XCTAssertEqual(page.items.count, 13)
        let video = try XCTUnwrap(page.items.first { $0.isVideo })
        XCTAssertEqual(video.handle, 0x40040100)
        XCTAssertEqual(video.size, 34_775_598)
        XCTAssertEqual(video.duration, 6)
        XCTAssertEqual(page.items.first { $0.filename.contains("0003") }?.size, 847_872)
    }
    func testSyntheticCustomNamingAndZeroCount() throws {
        var bytes = Data(repeating: 0, count: 12)
        let date = UInt32((2026 - 1980) << 9 | 10 << 5 | 3) << 16
        func path(_ text: String, sub: UInt8) -> Data { Data([0x1a, UInt8(text.utf8.count + 6), 0, 0, 0, sub]) + Data(text.utf8) }
        var metadata = Data(repeating: 0, count: 18)
        metadata.put32(date, at: 0); metadata.put32(12345, at: 4); metadata.put32(0x40040010, at: 8)
        metadata[16] = 0; metadata[17] = 0xff
        bytes.append(metadata); bytes.append(Data.hex("19060000000000"))
        bytes.append(path("DCIM/CUSTOM/自定义".replacingOccurrences(of: "自定义", with: "CUSTOM_NAME"), sub: 1))
        bytes.append(path("MISC/THM/CUSTOM/CUSTOM_NAME", sub: 2))
        let filename = "CUSTOM_NAME.JPG"
        bytes.append(Data([0x0c, 1, 0x0d, UInt8(filename.count)])); bytes.append(Data(filename.utf8))
        let page = try ManifestParser.decode(bytes, cameraID: "a", storage: .internalMemory)
        XCTAssertEqual(page.items.count, 1); XCTAssertTrue(page.lastPage)
        XCTAssertEqual(page.items[0].size, 12345)
        XCTAssertEqual(page.items[0].path, "DCIM/CUSTOM/CUSTOM_NAME.JPG")
        XCTAssertEqual(page.items[0].dayFolder, "2026-10-03")
        bytes.removeLast(5)
        XCTAssertThrowsError(try ManifestParser.decode(bytes, cameraID: "a", storage: .sd))
    }
}
