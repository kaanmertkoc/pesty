import AppKit

@MainActor
enum AppIconProvider {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bundleID else { return generic }
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        var image = generic
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let size = NSSize(width: 32, height: 32)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        thumbnail.unlockFocus()
        cache.setObject(thumbnail, forKey: bundleID as NSString)
        return thumbnail
    }

    static let generic: NSImage =
        NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        ?? NSImage()
}
