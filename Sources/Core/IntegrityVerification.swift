import Foundation
import CryptoKit

enum IntegrityVerification {
    // 将取消传递给后台校验，暂停大视频时无需等待整片读取完毕。
    static func sha256Cancellable(_ url: URL) async throws -> String {
        let task = Task.detached { try sha256(url) }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: { task.cancel() })
    }
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func committedFileMatches(_ record: TransferRecord) -> Bool {
        guard let checksum = record.checksum, record.total > 0 else { return false }
        let url = URL(fileURLWithPath: record.destination)
        guard FileManager.default.fileExists(atPath: url.path), LocalFiles.size(url) == record.total else { return false }
        return (try? sha256(url)) == checksum
    }
}
