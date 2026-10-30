import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum ClipPreviewProvider {
    struct FileInfo {
        let icon: NSImage
        let isMissing: Bool
    }

    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    // Decode one image at a time; rapid scrolling must not launch hundreds
    // of concurrent decodes, each with its own temporary buffers.
    private static let decodeQueue = DispatchQueue(label: "Pesty.previews", qos: .userInitiated)

    static func showsImage(_ item: ClipItem) -> Bool { item.type == .image }

    static func cachedImage(for item: ClipItem) -> NSImage? {
        guard let key = imageKey(for: item) else { return nil }
        return images.object(forKey: key)
    }

    static func image(for item: ClipItem, scale: CGFloat) async -> NSImage? {
        guard item.type == .image, !Task.isCancelled,
              let key = imageKey(for: item),
              let url = ClipboardStore.shared.imageURL(for: item) else { return nil }
        if let cached = images.object(forKey: key) { return cached }
        let loaded: NSImage? = await withCheckedContinuation { continuation in
            decodeQueue.async {
                continuation.resume(returning: autoreleasepool { Self.decode(url) })
            }
        }
        guard !Task.isCancelled, let loaded else { return nil }
        let rep = loaded.representations.first
        let cost = (rep?.pixelsWide ?? 0) * (rep?.pixelsHigh ?? 0) * 4
        images.setObject(loaded, forKey: key, cost: cost)
        return loaded
    }

    static func cachedIcon(for item: ClipItem) -> NSImage? { nil }

    /// Type icons use only the filename extension. Never stat, Quick Look, or
    /// decode the referenced original: it might trigger a cloud download.
    static func fileInfo(for item: ClipItem) async -> FileInfo? {
        guard item.type == .file,
              let url = item.fileURLs.first.flatMap(URL.init(string:)), url.isFileURL else { return nil }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return FileInfo(icon: NSWorkspace.shared.icon(for: type), isMissing: false)
    }

    private static func imageKey(for item: ClipItem) -> NSString? {
        guard item.type == .image,
              let path = ClipboardStore.shared.imageURL(for: item)?.path else { return nil }
        return "\(path)|\(item.imageHash ?? "")" as NSString
    }

    nonisolated private static func decode(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
