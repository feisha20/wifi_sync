import Foundation
import CryptoKit

enum SyncError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum CameraStorage: Int, Codable, CaseIterable, Identifiable {
    case sd = 0, internalMemory = 1
    var id: Int { rawValue }
    var title: String { self == .sd ? "SD 卡" : "内置存储" }
    var newestCursor: UInt32 { self == .sd ? 1 : 0x40000001 }
}

struct CameraDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let signal: Int
}

struct HotspotCredentials: Codable {
    let ssid: String
    let password: String
}

struct MediaItem: Codable, Identifiable, Hashable {
    let cameraID: String
    let storage: CameraStorage
    let path: String
    let thumbnailPath: String?
    let handle: UInt32
    let size: Int64
    let capturedAt: Date?
    let duration: Int
    var id: String { "\(cameraID)|\(storage.rawValue)|\(path)" }
    var version: String { "\(id)|\(size)|\(capturedAt?.timeIntervalSince1970 ?? 0)" }
    var filename: String { (path as NSString).lastPathComponent }
    var isVideo: Bool { ["mp4", "mov", "osv"].contains((path as NSString).pathExtension.lowercased()) }
    var groupBase: String? {
        let stem = (filename as NSString).deletingPathExtension
        guard let range = stem.range(of: "_[0-9]{3}$", options: .regularExpression) else { return nil }
        return String(stem[..<range.lowerBound])
    }
    var dayFolder: String {
        guard let date = capturedAt else { return "日期未知" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    // FAT 日期没有时区，按相机墙上时间存储；显示与整理都使用 UTC，避免跨时区偏移。
    static func cameraDate(_ packed: UInt32) -> Date? {
        let date = packed >> 16, time = packed & 0xffff
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = DateComponents(year: 1980 + Int(date >> 9), month: Int((date >> 5) & 15),
                               day: Int(date & 31), hour: Int(time >> 11),
                               minute: Int((time >> 5) & 63), second: Int((time & 31) * 2))
        guard (1...12).contains(c.month!), (1...31).contains(c.day!), c.hour! < 24,
              c.minute! < 60, c.second! < 60, let result = calendar.date(from: c),
              calendar.component(.month, from: result) == c.month,
              calendar.component(.day, from: result) == c.day else { return nil }
        return result
    }
}

enum Rendition { case original, thumbnail, photoPreview, proxy }

enum MediaAddress {
    static func candidates(for item: MediaItem, rendition: Rendition) throws -> [URL] {
        let primary = try url(for: item, rendition: rendition)
        guard rendition == .thumbnail || rendition == .photoPreview else { return [primary] }
        // Action 系列照片可能仅有 THM，视频通常提供 SCR。
        var fallback = URLComponents(url: primary, resolvingAgainstBaseURL: false)!
        fallback.queryItems = fallback.queryItems?.map {
            $0.name == "path" ? URLQueryItem(name: "path", value: (($0.value ?? "") as NSString).deletingPathExtension + ".thm") : $0
        }
        return [primary, fallback.url!]
    }
    static func url(for item: MediaItem, rendition: Rendition, host: String = "192.168.2.1") throws -> URL {
        var path = item.path
        switch rendition {
        case .original: break
        case .thumbnail, .photoPreview:
            guard let thumb = item.thumbnailPath else { throw SyncError.message("相机未提供预览图路径") }
            path = (thumb as NSString).deletingPathExtension + ".scr"
        case .proxy: path = (path as NSString).deletingPathExtension + ".LRF"
        }
        guard path.hasPrefix("DCIM/") || path.hasPrefix("MISC/"),
              !path.split(separator: "/").contains("..") else { throw SyncError.message("相机返回了无效素材路径") }
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.path = "/v2"
        components.queryItems = [URLQueryItem(name: "storage", value: String(item.storage.rawValue)),
                                URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { throw SyncError.message("无法构建素材地址") }
        return url
    }
}

func stableHash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
