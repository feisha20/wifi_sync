import Foundation

struct ManifestPage {
    let items: [MediaItem]
    let lastPage: Bool
    let declaredCount: Int
    func nextCursor(previous: UInt32, newest: Bool) throws -> UInt32? {
        if lastPage || items.count < 45 { return nil }
        let candidates = items.map(\.handle).filter { $0 != 0 && (newest || $0 < previous) }
        guard let next = candidates.min() else { throw SyncError.message("素材分页游标未推进，列表尚不完整") }
        return next
    }
}

enum ManifestParser {
    private static func pathField(_ bytes: Data, _ i: Int, subtype: UInt8, prefix: String) -> (String, Int)? {
        guard i >= 0, i + 6 <= bytes.count, bytes[i] == 0x1a, bytes[i + 1] >= 6,
              bytes[i + 2] == 0, bytes[i + 3] == 0, bytes[i + 4] == 0, bytes[i + 5] == subtype else { return nil }
        let end = i + Int(bytes[i + 1])
        guard end <= bytes.count else { return nil }
        let value = Data(bytes[(i + 6)..<end])
        guard value.allSatisfy({ (32...126).contains($0) }), let string = String(data: value, encoding: .ascii),
              string.hasPrefix(prefix), !string.split(separator: "/").contains("..") else { return nil }
        return (string, end)
    }

    static func decode(_ data: Data, cameraID: String, storage: CameraStorage) throws -> ManifestPage {
        let bytes = Data(data)
        var paths: [(offset: Int, end: Int, path: String)] = []
        var i = 0
        while i < bytes.count {
            if let (path, end) = pathField(bytes, i, subtype: 1, prefix: "DCIM/") {
                paths.append((i, end, path)); i = end
            } else { i += 1 }
        }
        // 每个字段只能读取自己记录范围内的内容，避免照片借用下一段视频的大小和句柄。
        var markers: [Int] = []
        for (index, path) in paths.enumerated() {
            let lower = index == 0 ? 0 : paths[index - 1].end
            let found = (max(lower + 18, 18)..<max(lower + 18, path.offset)).last {
                $0 + 1 < bytes.count && bytes[$0] == 0x19 && bytes[$0 + 1] == 6
            }
            guard let marker = found else { throw SyncError.message("素材记录缺少元数据标记，拒绝使用不完整列表") }
            markers.append(marker)
        }
        var items: [MediaItem] = []
        var last = false
        for (index, path) in paths.enumerated() {
            let marker = markers[index]
            let lower = marker - 18
            let upper = index + 1 < paths.count ? markers[index + 1] - 18 : bytes.count
            guard upper > path.end - 1 else { throw SyncError.message("素材记录边界异常") }
            let basename = (path.path as NSString).lastPathComponent
            var filename: String?
            var thumb: String?
            i = max(0, lower)
            while i + 2 <= upper {
                if bytes[i] == 0x0c, bytes[i + 1] == 1 { last = true }
                if bytes[i] == 0x0d {
                    let end = i + 2 + Int(bytes[i + 1])
                    if end <= upper, let name = String(data: bytes[(i + 2)..<end], encoding: .ascii),
                       name.hasPrefix(basename + "."), !name.contains("/") {
                        let ext = (name as NSString).pathExtension.uppercased()
                        if ["MP4", "MOV", "JPG", "JPEG", "DNG", "HEIC", "TIFF", "PANO", "OSV"].contains(ext) { filename = name }
                    }
                }
                if let (value, _) = pathField(bytes, i, subtype: 2, prefix: "MISC/") { thumb = value }
                i += 1
            }
            guard let filename else { throw SyncError.message("素材扩展名未解析，列表尚不完整") }
            let fullPath = (path.path as NSString).deletingLastPathComponent + "/" + filename
            let type = bytes[marker - 2]
            items.append(MediaItem(cameraID: cameraID, storage: storage, path: fullPath, thumbnailPath: thumb,
                                   handle: bytes.u32(marker - 10), size: Int64(bytes.u32(marker - 14)),
                                   capturedAt: MediaItem.cameraDate(bytes.u32(marker - 18)),
                                   duration: [2, 3, 44].contains(type) ? Int(bytes.u16(marker - 6)) : 0))
        }
        let count = bytes.count >= 4 ? Int(bytes.u32(0)) : 0
        if (1...255).contains(count), items.count < count { throw SyncError.message("素材列表记录数不足，请重试") }
        if !bytes.isEmpty && paths.isEmpty && count != 0 { throw SyncError.message("相机返回了无法识别的素材列表") }
        return ManifestPage(items: items, lastPage: last, declaredCount: count)
    }
}

struct ManifestCollector {
    let counter: UInt16
    private(set) var started = false
    private(set) var ended = false
    private var chunks: [UInt32: Data] = [:]
    init(counter: UInt16) { self.counter = counter }
    mutating func receive(_ frame: DUMLFrame) throws {
        let p = frame.payload
        guard frame.commandSet == 0, frame.command == 0x27, p.count >= 10,
              p[0] == 0x4a, p.u16(4) == counter else { return }
        switch p[1] {
        case 4: started = true
        case 3: ended = true
        case 1:
            let number = p.u32(6), bytes = Data(p.dropFirst(10))
            if let old = chunks[number], old != bytes { throw SyncError.message("素材数据分块冲突") }
            chunks[number] = bytes
        default: break
        }
    }
    func manifest() throws -> Data {
        guard ended else { throw SyncError.message("素材列表接收超时，不能视为完整列表") }
        let indices = chunks.keys.sorted()
        if let first = indices.first, let last = indices.last,
           first != 0 || Int(last - first + 1) != indices.count { throw SyncError.message("素材列表丢失数据分块，请重试") }
        return indices.reduce(into: Data()) { $0.append(chunks[$1]!) }
    }
}
