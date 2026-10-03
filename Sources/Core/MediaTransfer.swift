import Foundation

struct HTTPDownloadPlan: Equatable {
    let offset: Int64
    let total: Int64
    static func validate(status: Int, headers: [String: String], offset: Int64, expected: Int64) throws -> HTTPDownloadPlan {
        let headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        guard status == 200 || status == 206 else { throw SyncError.message("相机下载返回 HTTP \(status)") }
        let start: Int64, total: Int64
        if status == 206 {
            guard let value = headers["content-range"], let match = value.range(of: "^bytes [0-9]+-[0-9]+/[0-9]+$", options: .regularExpression), match == value.startIndex..<value.endIndex else {
                throw SyncError.message("续传响应缺少有效字节范围")
            }
            let values = value.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int64($0) }
            guard values.count == 3, values[0] == offset, values[1] >= offset, values[2] > values[1],
                  let length = headers["content-length"].flatMap(Int64.init), length == values[1] - values[0] + 1 else {
                throw SyncError.message("续传范围与本地文件不匹配")
            }
            start = offset; total = values[2]
        } else {
            // Range 被忽略时截断临时文件，绝不能将整片追加到旧片尾部。
            guard let length = headers["content-length"].flatMap(Int64.init), length > 0 else { throw SyncError.message("下载响应未提供文件长度") }
            start = 0; total = length
        }
        // 清单的大小字段为 u32；大于 4 GiB 的文件以 HTTP 的完整长度为准。
        guard expected == 0 || expected == total || (total > Int64(UInt32.max) && expected == Int64(UInt32(truncatingIfNeeded: total))) else {
            throw SyncError.message("相机文件长度已变化，请刷新素材列表后重试")
        }
        return HTTPDownloadPlan(offset: start, total: total)
    }
}

// 将每个 URLSession 数据分块直接写盘，原片大小不影响内存占用。
final class DownloadOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let remote: URL
    private let destination: URL
    private let expected: Int64
    private let progress: @Sendable (Int64, Int64, Double) -> Void
    private let configurationOverride: URLSessionConfiguration?
    private let cancellation = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Int64, Error>?
    private var handle: FileHandle?
    private var initialOffset: Int64 = 0
    private var received: Int64 = 0
    private var total: Int64 = 0
    private var responseError: Error?
    private var started = Date()
    private var lastProgress = Date.distantPast
    private var rangeStart: Int64 = 0

    init(remote: URL, destination: URL, expected: Int64, configuration: URLSessionConfiguration? = nil,
         progress: @escaping @Sendable (Int64, Int64, Double) -> Void) {
        self.remote = remote; self.destination = destination; self.expected = expected; self.progress = progress
        self.configurationOverride = configuration
    }
    func run() async throws -> Int64 {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw SyncError.message("无法创建下载临时文件，请检查目录权限和磁盘空间") }
                    }
                    initialOffset = LocalFiles.size(destination)
                    handle = try FileHandle(forWritingTo: destination)
                    let configuration = configurationOverride ?? URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 20
                    configuration.timeoutIntervalForResource = 24 * 60 * 60
                    configuration.waitsForConnectivity = false
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
                    self.session = session
                    var request = URLRequest(url: remote)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    if initialOffset > 0 { request.setValue("bytes=\(initialOffset)-", forHTTPHeaderField: "Range") }
                    let task = session.dataTask(with: request)
                    cancellation.lock(); self.task = task; let wasCancelled = cancelled; cancellation.unlock()
                    if wasCancelled { task.cancel() }; task.resume()
                } catch { finish(error: error) }
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() { cancellation.lock(); cancelled = true; task?.cancel(); cancellation.unlock() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw SyncError.message("无法识别相机下载响应") }
            var headers: [String: String] = [:]
            response.allHeaderFields.forEach { headers[String(describing: $0.key)] = String(describing: $0.value) }
            // 文件已经完整落盘、尚未来得及更新数据库时，HTTP 416 可证明字节范围已到文件尾。
            if response.statusCode == 416, let raw = response.value(forHTTPHeaderField: "Content-Range"),
               raw.hasPrefix("bytes */"), let length = Int64(raw.dropFirst(8)), length > 0, length == initialOffset,
               expected == 0 || expected == length || (length > Int64(UInt32.max) && expected == Int64(UInt32(truncatingIfNeeded: length))) {
                received = length; total = length; completionHandler(.cancel); return
            }
            let plan = try HTTPDownloadPlan.validate(status: response.statusCode, headers: headers, offset: initialOffset, expected: expected)
            try handle?.truncate(atOffset: UInt64(plan.offset)); try handle?.seek(toOffset: UInt64(plan.offset))
            received = plan.offset; rangeStart = plan.offset; total = plan.total; started = Date()
            progress(received, total, 0); completionHandler(.allow)
        } catch { responseError = error; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard received + Int64(data.count) <= total else { throw SyncError.message("相机发送的数据超出声明长度") }
            try handle?.write(contentsOf: data); received += Int64(data.count)
            if Date().timeIntervalSince(lastProgress) >= 0.15 {
                progress(received, total, Double(received - rangeStart) / max(0.1, Date().timeIntervalSince(started))); lastProgress = Date()
            }
        } catch { responseError = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cancellation.lock(); let wasCancelled = cancelled; cancellation.unlock()
        if wasCancelled { finish(error: CancellationError()); return }
        if let responseError { finish(error: responseError); return }
        // 416 情况在响应回调中已经严格校验；其他网络错误仍不能算下载完成。
        let isCompleteRange = (task.response as? HTTPURLResponse)?.statusCode == 416 && total > 0 && received == total
        if let error, !isCompleteRange { finish(error: error); return }
        guard total > 0, received == total, LocalFiles.size(destination) == total else {
            finish(error: SyncError.message("文件未下载完整，保留临时文件以便续传")); return
        }
        progress(received, total, 0); finish(error: nil)
    }
    private func finish(error: Error?) {
        do { try handle?.synchronize(); try handle?.close() } catch {
            responseError = error
        }
        handle = nil
        let result = continuation; continuation = nil
        session?.finishTasksAndInvalidate(); session = nil
        if let error = error ?? responseError { result?.resume(throwing: error) } else { result?.resume(returning: total) }
    }
}

enum MediaTransfer {
    static func download(remote: URL, partial: URL, expected: Int64,
                         attempts: Int = 3, progress: @escaping @Sendable (Int64, Int64, Double) -> Void) async throws -> Int64 {
        var lastError: Error = SyncError.message("下载失败")
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do { return try await DownloadOperation(remote: remote, destination: partial, expected: expected, progress: progress).run() }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                lastError = error
                if attempt + 1 < attempts { try await Task.sleep(for: .seconds(pow(2, Double(attempt)))) }
            }
        }
        throw lastError
    }
    static func commit(partial: URL, destination: URL, total: Int64) throws {
        guard total > 0, LocalFiles.size(partial) == total else { throw SyncError.message("临时文件长度不完整") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw SyncError.message("目标文件已存在，保留临时文件以避免覆盖") }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
