import XCTest
@testable import WiFiSyncCore

final class StubProtocol: URLProtocol {
    static var responder: (URLRequest) throws -> (Int, [String: String], Data, Error?) = { _ in (500, [:], Data(), nil) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data, error) = try Self.responder(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            if let error {
                // 给 URLSession 完成响应授权和数据回调的机会，再模拟连接断开。
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in client?.urlProtocol(self, didFailWithError: error) }
            } else { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class TransferTests: XCTestCase {
    private func folder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    private func operation(_ url: URL, size: Int64 = 8) -> DownloadOperation {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return DownloadOperation(remote: URL(string: "http://192.168.2.1/v2")!, destination: url, expected: size,
                                 configuration: config, progress: { _, _, _ in })
    }
    func testRangeValidationAndLargeLength() throws {
        XCTAssertEqual(try HTTPDownloadPlan.validate(status: 206, headers: ["Content-Range": "bytes 4-7/8", "Content-Length": "4"], offset: 4, expected: 8), HTTPDownloadPlan(offset: 4, total: 8))
        XCTAssertEqual(try HTTPDownloadPlan.validate(status: 200, headers: ["Content-Length": "8"], offset: 4, expected: 8).offset, 0)
        XCTAssertThrowsError(try HTTPDownloadPlan.validate(status: 206, headers: ["Content-Range": "bytes 3-7/8", "Content-Length": "5"], offset: 4, expected: 8))
        XCTAssertThrowsError(try HTTPDownloadPlan.validate(status: 206, headers: [:], offset: 4, expected: 8))
        XCTAssertThrowsError(try HTTPDownloadPlan.validate(status: 500, headers: [:], offset: 0, expected: 8))
        XCTAssertEqual(try HTTPDownloadPlan.validate(status: 200, headers: ["Content-Length": "5368709120"], offset: 0, expected: 1073741824).total, 5_368_709_120)
    }
    func testRangeIgnoredRestartsInsteadOfAppending() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("file.part")
        try Data("OLD!".utf8).write(to: partial)
        StubProtocol.responder = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4-")
            return (200, ["Content-Length": "8"], Data("12345678".utf8), nil)
        }
        let total = try await operation(partial).run()
        XCTAssertEqual(total, 8); XCTAssertEqual(try Data(contentsOf: partial), Data("12345678".utf8))
    }
    func testInterruptedDownloadResumes() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("file.part")
        // 提前 EOF：声明 8 字节却只交付 4 字节，下载器必须保留已写入分块而不能提交完成。
        StubProtocol.responder = { _ in (200, ["Content-Length": "8"], Data("1234".utf8), nil) }
        do { _ = try await operation(partial).run(); XCTFail("中断文件不能成功") } catch { }
        XCTAssertEqual(LocalFiles.size(partial), 4)
        StubProtocol.responder = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=4-")
            return (206, ["Content-Length": "4", "Content-Range": "bytes 4-7/8"], Data("5678".utf8), nil)
        }
        _ = try await operation(partial).run()
        XCTAssertEqual(try Data(contentsOf: partial), Data("12345678".utf8))
        let destination = root.appendingPathComponent("file.mp4")
        try MediaTransfer.commit(partial: partial, destination: destination, total: 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(LocalFiles.size(destination), 8)
    }
    func testBadRangeKeepsPartialAndNoFalseSuccess() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("file.part")
        try Data("1234".utf8).write(to: partial)
        StubProtocol.responder = { _ in (206, ["Content-Length": "4", "Content-Range": "bytes 0-3/8"], Data("5678".utf8), nil) }
        do { _ = try await operation(partial).run(); XCTFail("错误范围不能成功") } catch { }
        XCTAssertEqual(try Data(contentsOf: partial), Data("1234".utf8))
        XCTAssertThrowsError(try MediaTransfer.commit(partial: partial, destination: root.appendingPathComponent("original"), total: 8))
    }
    func testSQLiteRestartAndMissingOriginal() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.sqlite")
        let original = root.appendingPathComponent("original.mp4")
        try Data("12345678".utf8).write(to: original)
        let record = TransferRecord(item: ProtocolTests.item(size: 8), destination: original.path, state: .complete, bytes: 8, total: 8)
        let store = try StateStore(url: database); try await store.save(record)
        let reopened = try StateStore(url: database)
        let records = try await reopened.records()
        XCTAssertEqual(records.count, 1); XCTAssertTrue(LocalFiles.validCompleted(records[0]))
        try FileManager.default.removeItem(at: original)
        XCTAssertFalse(LocalFiles.validCompleted(records[0]))
    }
    func testCollisionAndSHA256() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let item = ProtocolTests.item(path: "DCIM/a.JPG")
        let first = try LocalFiles.destination(for: item, root: root, reserved: [])
        try Data("abc".utf8).write(to: first)
        let second = try LocalFiles.destination(for: item, root: root, reserved: [])
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try IntegrityVerification.sha256(first), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try MediaTransfer.commit(partial: first, destination: first, total: 3))
    }
    func testFinalizationReceiptRecoveryAndChangedFile() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original")
        try Data("abc".utf8).write(to: url)
        var record = TransferRecord(item: ProtocolTests.item(size: 3), destination: url.path, state: .finalizing, bytes: 3, total: 3)
        record.checksum = try IntegrityVerification.sha256(url)
        XCTAssertTrue(IntegrityVerification.committedFileMatches(record))
        try Data("xyz".utf8).write(to: url)
        XCTAssertFalse(IntegrityVerification.committedFileMatches(record))
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(IntegrityVerification.committedFileMatches(record))
    }
    func testCompletePartialUsesStrict416Response() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent("file.part")
        try Data("12345678".utf8).write(to: partial)
        StubProtocol.responder = { _ in (416, ["Content-Range": "bytes */8"], Data(), nil) }
        let total = try await operation(partial).run()
        XCTAssertEqual(total, 8)
        StubProtocol.responder = { _ in (416, ["Content-Range": "bytes */9"], Data(), nil) }
        do { _ = try await operation(partial).run(); XCTFail("不匹配的 416 不能成功") } catch { }
    }
}
