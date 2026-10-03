import Foundation
import SQLite3

enum TransferState: String, Codable { case queued, downloading, finalizing, paused, failed, complete }
struct TransferRecord: Codable, Identifiable {
    let item: MediaItem
    var destination: String
    var state: TransferState
    var bytes: Int64 = 0
    var total: Int64 = 0
    var error: String?
    var checksum: String?
    var id: String { item.version }
}

actor StateStore {
    private var db: OpaquePointer?
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SyncError.message("无法打开同步数据库") }
        sqlite3_busy_timeout(db, 5000)
        let sql = "PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS transfers (version TEXT PRIMARY KEY, record BLOB NOT NULL);"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SyncError.message("无法初始化同步数据库") }
    }
    deinit { sqlite3_close(db) }
    func save(_ record: TransferRecord) throws {
        let bytes = try JSONEncoder().encode(record)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO transfers VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, record.id, -1, transient)
        bytes.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(bytes.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }
    func records() throws -> [TransferRecord] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT record FROM transfers ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        var result: [TransferRecord] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard let pointer = sqlite3_column_blob(statement, 0) else { throw SyncError.message("同步记录损坏") }
            result.append(try JSONDecoder().decode(TransferRecord.self, from: Data(bytes: pointer, count: count)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw databaseError() }
        return result
    }
    private func databaseError() -> SyncError { .message("同步数据库错误：\(String(cString: sqlite3_errmsg(db)))") }
}

enum LocalFiles {
    static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
    static func validCompleted(_ record: TransferRecord) -> Bool {
        record.state == .complete && FileManager.default.fileExists(atPath: record.destination)
            && size(URL(fileURLWithPath: record.destination)) == record.total && record.total > 0
    }
    static func destination(for item: MediaItem, root: URL, reserved: Set<String>) throws -> URL {
        guard !item.filename.isEmpty, item.filename != ".", item.filename != "..", !item.filename.contains(":") else { throw SyncError.message("素材文件名无效") }
        let folder = root.appendingPathComponent(item.dayFolder).appendingPathComponent(item.storage.title)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent(item.filename)
        var candidate = original, index = 1
        while FileManager.default.fileExists(atPath: candidate.path) || FileManager.default.fileExists(atPath: candidate.path + ".part") || reserved.contains(candidate.path) {
            candidate = folder.appendingPathComponent("\((item.filename as NSString).deletingPathExtension)_\(index).\((item.filename as NSString).pathExtension)")
            index += 1
        }
        return candidate
    }
}
