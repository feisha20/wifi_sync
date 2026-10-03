import SwiftUI
import AVFoundation
import AppKit
import ImageIO

@MainActor
final class AppModel: ObservableObject {
    let discovery = CameraDiscovery()
    @Published var camera: CameraDevice?
    @Published var credentials: HotspotCredentials?
    @Published var firmware = "未连接"
    @Published var connected = false
    @Published var busy = false
    @Published var scanComplete = false
    @Published var media: [MediaItem] = []
    @Published var selection = Set<String>()
    @Published var storageFilter: Int = -1
    @Published var kindFilter = 0
    @Published var search = ""
    @Published var records: [TransferRecord] = []
    @Published var destination: URL?
    @Published var errorMessage: String?
    @Published var logs: [String] = []
    @Published var speed: Double = 0
    @Published var running = false
    @Published var enqueuing = false
    @Published var previewItem: MediaItem?
    @Published var previewImage: NSImage?
    @Published var player: AVPlayer?
    @Published var previewStatus = "选择一项素材进行预览"
    @Published var previewNeedsOriginal = false
    @Published var thumbnails: [String: NSImage] = [:]
    private var operation: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var store: StateStore?
    private var rootAccess = false
    private var generation = UUID()
    private var cache: PreviewCache
    private lazy var session = CameraSession(log: { [weak self] text in Task { @MainActor in self?.addLog(text) } }, disconnected: { [weak self] text in
        Task { @MainActor in self?.connectionFailed(text) }
    })

    init() {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WiFiSync")
        cache = PreviewCache(root: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("WiFiSync/预览"))
        do { store = try StateStore(url: support.appendingPathComponent("同步记录.sqlite")) }
        catch { errorMessage = error.localizedDescription }
        discovery.log = { [weak self] text in self?.addLog(text) }
        discovery.onDisconnect = { [weak self] text in self?.connectionFailed(text) }
        restoreDestination()
        Task {
            do {
                records = try await store?.records() ?? []
                for index in records.indices {
                    let record = records[index]
                    if record.state != .complete, record.checksum != nil {
                        let verified = await Task.detached { IntegrityVerification.committedFileMatches(record) }.value
                        if verified { records[index].state = .complete; try await store?.save(records[index]); continue }
                    }
                    if records[index].state == .downloading || records[index].state == .queued || records[index].state == .finalizing {
                        records[index].state = .paused
                        records[index].bytes = LocalFiles.size(URL(fileURLWithPath: records[index].destination + ".part"))
                        try await store?.save(records[index])
                    }
                }
                // 重启后已同步素材仍可离线浏览，无需重新连接相机才能点击预览。
                if media.isEmpty, camera == nil {
                    var seen = Set<String>()
                    media = sorted(records.filter(LocalFiles.validCompleted).reversed().compactMap {
                        seen.insert($0.item.id).inserted ? $0.item : nil
                    })
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    var filteredMedia: [MediaItem] {
        media.filter { (storageFilter == -1 || $0.storage.rawValue == storageFilter)
            && (kindFilter == 0 || (kindFilter == 1 ? !$0.isVideo : $0.isVideo))
            && (search.isEmpty || $0.filename.localizedCaseInsensitiveContains(search)) }
    }
    var completedVersions: Set<String> { Set(records.filter(LocalFiles.validCompleted).map { $0.item.version }) }
    var selectedItems: [MediaItem] { media.filter { selection.contains($0.id) } }
    var remainingCount: Int { media.filter { !completedVersions.contains($0.version) }.count }
    func addLog(_ text: String) {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        logs.append("\(formatter.string(from: Date()))  \(text)")
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }
    func prepare(_ device: CameraDevice) {
        guard !busy, !running else { return }
        busy = true; scanComplete = false; connected = false; camera = device; credentials = nil
        media = []; selection = []; thumbnails = [:]; previewTask?.cancel(); player?.pause()
        operation = Task {
            await session.close()
            await cache.cancelAll()
            do { credentials = try await discovery.prepare(device) }
            catch { errorMessage = error.localizedDescription; addLog("配对失败：\(error.localizedDescription)") }
            busy = false
        }
    }
    func connectAndScan() {
        guard !busy, !running, let camera, credentials != nil else { return }
        busy = true; scanComplete = false
        generation = UUID(); let current = generation
        operation = Task {
            do {
                firmware = try await session.open(identifier: CredentialStore.identifier)
                connected = true
                let result = try await session.listAll(cameraID: camera.id.uuidString) { [weak self] page in
                    Task { @MainActor in
                        guard let self, self.generation == current, !self.scanComplete else { return }
                        self.media = self.sorted(page)
                    }
                }
                media = sorted(result); scanComplete = true
                addLog("完整扫描完成：\(media.count) 项素材")
            } catch {
                scanComplete = false
                errorMessage = error.localizedDescription; addLog("读取未完成：\(error.localizedDescription)")
                connected = await session.isReady
                if !connected { await session.close() }
            }
            busy = false
        }
    }
    private func sorted(_ items: [MediaItem]) -> [MediaItem] {
        items.sorted { if $0.capturedAt == $1.capturedAt { return $0.id < $1.id }; return ($0.capturedAt ?? .distantPast) > ($1.capturedAt ?? .distantPast) }
    }
    func connectionFailed(_ text: String) {
        connected = false; scanComplete = false; queueTask?.cancel()
        addLog(text); errorMessage = text
    }
    func disconnect() {
        operation?.cancel(); queueTask?.cancel(); previewTask?.cancel(); generation = UUID()
        player?.pause(); connected = false; scanComplete = false; credentials = nil
        discovery.disconnect()
        Task { await session.close(); await cache.cancelAll() }
    }
    func chooseDestination() {
        guard !running, !enqueuing else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择素材保存目录，应用会按拍摄日期创建子文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            if rootAccess, let destination { destination.stopAccessingSecurityScopedResource() }
            rootAccess = url.startAccessingSecurityScopedResource(); destination = url
            UserDefaults.standard.set(data, forKey: "destinationBookmark")
            addLog("保存目录已设置")
        } catch { errorMessage = "无法保存目录访问权限：\(error.localizedDescription)" }
    }
    private func restoreDestination() {
        guard let data = UserDefaults.standard.data(forKey: "destinationBookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            rootAccess = url.startAccessingSecurityScopedResource(); destination = url
            if stale { UserDefaults.standard.set(try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil), forKey: "destinationBookmark") }
        } catch { addLog("保存目录需要重新选择") }
    }
    func enqueue(_ items: [MediaItem]) {
        guard !enqueuing else { return }
        guard connected, let destination, let store else { errorMessage = "请连接相机并选择保存目录"; return }
        enqueuing = true
        Task {
            defer { enqueuing = false }
            do {
                var reserved = Set(records.map(\.destination))
                for item in items where !completedVersions.contains(item.version) {
                    if let index = records.firstIndex(where: { $0.id == item.version }) {
                        if records[index].state != .downloading {
                            guard isInsideRoot(records[index].destination) else { throw SyncError.message("已有任务属于其他保存目录，请重新选择该目录后恢复") }
                            // 已完成文件被用户移走时，重建任务并选择新的安全目标位置。
                            if records[index].state == .complete || FileManager.default.fileExists(atPath: records[index].destination) {
                                let previousPartial = URL(fileURLWithPath: records[index].destination + ".part")
                                let next = try LocalFiles.destination(for: item, root: destination, reserved: reserved)
                                if FileManager.default.fileExists(atPath: previousPartial.path) {
                                    try FileManager.default.moveItem(at: previousPartial, to: next.appendingPathExtension("part"))
                                }
                                records[index].destination = next.path
                                reserved.insert(records[index].destination)
                            }
                            records[index].state = .queued; records[index].error = nil
                            try await store.save(records[index])
                        }
                    } else {
                        let url = try LocalFiles.destination(for: item, root: destination, reserved: reserved)
                        let record = TransferRecord(item: item, destination: url.path, state: .queued, total: item.size)
                        try await store.save(record); records.append(record); reserved.insert(url.path)
                    }
                }
                startQueue()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func isInsideRoot(_ path: String) -> Bool {
        guard let destination else { return false }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(destination.resolvingSymlinksInPath().path + "/")
    }
    func resumeQueue() {
        guard connected, destination != nil else { errorMessage = "请连接相机并选择原保存目录"; return }
        enqueue(records.filter { $0.state == .paused || $0.state == .failed || $0.state == .queued }.map(\.item))
    }
    func pauseQueue() { queueTask?.cancel() }
    private func startQueue() {
        guard !running, connected, let store else { return }
        running = true
        queueTask = Task {
            defer { running = false; speed = 0 }
            while let index = records.firstIndex(where: { $0.state == .queued }), !Task.isCancelled {
                var record = records[index]
                do {
                    guard isInsideRoot(record.destination) else { throw SyncError.message("任务保存目录不可用，请选择原保存目录") }
                    let target = URL(fileURLWithPath: record.destination), partial = target.appendingPathExtension("part")
                    if FileManager.default.fileExists(atPath: target.path) {
                        // 原子改名后、提交数据库前崩溃：不能仅凭长度认定文件归属于此任务。
                        throw SyncError.message("目标文件已存在，请在 Finder 检查后重新加入任务，应用不会覆盖")
                    }
                    record.state = .downloading; record.error = nil; records[index] = record; try await store.save(record)
                    let id = record.id
                    let total = try await MediaTransfer.download(remote: MediaAddress.url(for: record.item, rendition: .original), partial: partial,
                                                                 expected: record.item.size, progress: { [weak self] bytes, total, speed in
                        Task { @MainActor in
                            guard let self, let i = self.records.firstIndex(where: { $0.id == id }), self.records[i].state == .downloading else { return }
                            self.records[i].bytes = bytes; self.records[i].total = total; self.speed = speed
                        }
                    })
                    try Task.checkCancellation()
                    // 先记录待提交文件的内容指纹，再原子改名，便于恢复“改名后尚未写完数据库”的退出。
                    record.state = .finalizing; record.total = total; record.bytes = total
                    records[index] = record
                    record.checksum = try await IntegrityVerification.sha256Cancellable(partial)
                    try Task.checkCancellation()
                    try await store.save(record); records[index] = record
                    try MediaTransfer.commit(partial: partial, destination: target, total: total)
                    record.state = .complete; record.bytes = total; record.total = total
                    try await store.save(record); records[index] = record
                    addLog("同步完成：\(record.item.filename)")
                    if previewItem?.version == record.item.version { preview(record.item) }
                } catch {
                    record.bytes = LocalFiles.size(URL(fileURLWithPath: record.destination + ".part"))
                    record.state = Task.isCancelled ? .paused : .failed
                    record.error = Task.isCancelled ? nil : error.localizedDescription
                    records[index] = record
                    do { try await store.save(record) } catch { errorMessage = error.localizedDescription; return }
                    if !Task.isCancelled { addLog("下载失败：\(record.item.filename)：\(error.localizedDescription)") }
                }
            }
            if Task.isCancelled {
                for index in records.indices where records[index].state == .queued {
                    records[index].state = .paused
                    do { try await store.save(records[index]) } catch { errorMessage = error.localizedDescription }
                }
            }
        }
    }
    func thumbnail(_ item: MediaItem) async {
        guard thumbnails[item.version] == nil else { return }
        do {
            let url: URL
            if let saved = records.first(where: { $0.item.version == item.version && LocalFiles.validCompleted($0) }) {
                url = URL(fileURLWithPath: saved.destination)
                if item.isVideo {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 400, height: 400)
                    let result = try await generator.image(at: .zero)
                    thumbnails[item.version] = NSImage(cgImage: result.image, size: CGSize(width: result.image.width, height: result.image.height))
                    return
                }
            } else {
                guard connected else { return }
                url = try await cache.resource(item, rendition: .thumbnail)
            }
            if thumbnails.count > 300 { thumbnails.removeAll() }
            thumbnails[item.version] = image(url, pixels: 400)
        } catch { /* 缩略图失败保留类型占位图，原片下载仍可重试。 */ }
    }
    func preview(_ item: MediaItem) {
        previewTask?.cancel(); player?.pause(); player = nil; previewImage = nil
        previewItem = item; previewNeedsOriginal = false; previewStatus = "正在准备预览…"
        previewTask = Task {
            do {
                let url: URL
                if let saved = records.first(where: { $0.item.version == item.version && LocalFiles.validCompleted($0) }) {
                    url = URL(fileURLWithPath: saved.destination)
                } else if item.isVideo {
                    guard connected else { throw SyncError.message("请连接相机后预览") }
                    url = try await cache.resource(item, rendition: .proxy)
                } else {
                    guard connected else { throw SyncError.message("请连接相机后预览") }
                    do { url = try await cache.resource(item, rendition: .photoPreview) }
                    catch { url = try await cache.resource(item, rendition: .original) }
                }
                try Task.checkCancellation()
                if item.isVideo {
                    let asset = AVURLAsset(url: url)
                    guard try await asset.load(.isPlayable) else { throw SyncError.message("此视频预览格式无法播放") }
                    try Task.checkCancellation(); player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    previewStatus = completedVersions.contains(item.version) ? "本地原片" : "低清视频预览 · 同步时保存原片"
                } else {
                    guard let loaded = image(url, pixels: 2400) else { throw SyncError.message("无法解码照片预览") }
                    previewImage = loaded; previewStatus = "照片预览"
                }
            } catch {
                guard !Task.isCancelled else { return }
                let isLocal = records.contains { $0.item.version == item.version && LocalFiles.validCompleted($0) }
                previewNeedsOriginal = item.isVideo && !isLocal
                previewStatus = item.isVideo && !isLocal ? "视频代理预览失败：\(error.localizedDescription)。可下载原片后预览" : error.localizedDescription
                addLog("预览失败：\(item.filename)：\(error.localizedDescription)")
            }
        }
    }
    private func image(_ url: URL, pixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
    func reveal(_ record: TransferRecord) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.destination)]) }
    func verify(_ record: TransferRecord) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "选择通过 USB 导出的同一原片，比较 SHA-256"
        guard panel.runModal() == .OK, let reference = panel.url else { return }
        let scoped = reference.startAccessingSecurityScopedResource()
        addLog("正在计算 SHA-256：\(record.item.filename)")
        Task {
            defer { if scoped { reference.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await Task.detached {
                    let local = try IntegrityVerification.sha256(URL(fileURLWithPath: record.destination))
                    let original = try IntegrityVerification.sha256(reference)
                    return (local, original)
                }.value
                addLog("SHA-256 \(result.0 == result.1 ? "一致，原片校验通过" : "不一致，请确认选中同一文件")：\(record.item.filename)")
                addLog("无线文件：\(result.0)；USB 文件：\(result.1)")
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func shutdown() async {
        operation?.cancel(); queueTask?.cancel(); previewTask?.cancel()
        await queueTask?.value
        await cache.cancelAll()
        await session.close(); discovery.disconnect()
        if rootAccess, let destination { destination.stopAccessingSecurityScopedResource(); rootAccess = false }
    }
}
