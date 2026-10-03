import Foundation

actor PreviewCache {
    private let root: URL
    private var active = 0
    private var tasks: [String: Task<URL, Error>] = [:]
    init(root: URL) { self.root = root }
    func cancelAll() async {
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }
        for task in pending { _ = try? await task.value }
        tasks = [:]
    }
    func resource(_ item: MediaItem, rendition: Rendition) async throws -> URL {
        let kind: String
        switch rendition { case .original: kind = "original"; case .thumbnail: kind = "thumb"; case .photoPreview: kind = "photo"; case .proxy: kind = "proxy" }
        let key = stableHash(item.version + kind)
        if let task = tasks[key] { return try await task.value }
        let ext = rendition == .proxy ? "mp4" : "jpg"
        let target = root.appendingPathComponent(key + "." + ext)
        if LocalFiles.size(target) > 0 { return target }
        let task = Task<URL, Error> {
            while active >= 4 { try await Task.sleep(for: .milliseconds(50)) }
            active += 1; defer { active -= 1 }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let partial = target.appendingPathExtension("part")
            var lastError: Error = SyncError.message("预览资源不可用")
            var downloaded = false
            for remote in try MediaAddress.candidates(for: item, rendition: rendition) {
                try Task.checkCancellation()
                do {
                    let total = try await MediaTransfer.download(remote: remote, partial: partial,
                                                                 expected: rendition == .original ? item.size : 0,
                                                                 attempts: 1, progress: { _, _, _ in })
                    try MediaTransfer.commit(partial: partial, destination: target, total: total)
                    downloaded = true; break
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    lastError = error
                    // 不同预览文件之间不能共用旧文件的续传偏移。
                    if LocalFiles.size(partial) > 0 {
                        let handle = try FileHandle(forWritingTo: partial)
                        defer { try? handle.close() }
                        try handle.truncate(atOffset: 0)
                    }
                }
            }
            guard downloaded else { throw lastError }
            prune(keeping: target)
            return target
        }
        tasks[key] = task
        do { let result = try await task.value; tasks[key] = nil; return result }
        catch { tasks[key] = nil; throw error }
    }
    private func prune(keeping: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let files = urls.filter { $0.pathExtension != "part" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var total = files.reduce(Int64(0)) { $0 + LocalFiles.size($1) }
        for file in files where file != keeping && total > 1_073_741_824 {
            let size = LocalFiles.size(file)
            if (try? FileManager.default.removeItem(at: file)) != nil { total -= size }
        }
    }
}
