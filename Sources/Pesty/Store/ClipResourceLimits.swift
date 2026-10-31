import Foundation
import ImageIO

/// Limits automatic capture and retention. Pinboards are explicitly saved by
/// the user and are never silently pruned by these history budgets.
enum ClipResourceLimits {
    static let textBytes = 1024 * 1024
    static let richTextBytes = 1024 * 1024
    static let imageBytes = 16 * 1024 * 1024
    static let imagePixels = 24_000_000
    // Clipboard TIFFs commonly contain uncompressed RGBA pixels. Allow the
    // pixel budget plus metadata while converting, then enforce imageBytes
    // on the PNG that is actually retained in history.
    static let clipboardTIFFBytes = imagePixels * 4 + 1024 * 1024
    static let historyPayloadBytes = 32 * 1024 * 1024
    static let historyImageBytes = 256 * 1024 * 1024
    static let maximumHistoryCount = 5000
    static let maximumStoreBytes = 128 * 1024 * 1024

    static func acceptsText(_ text: String) -> Bool {
        text.utf8.count <= textBytes
    }

    static func boundedRTF(_ data: Data?) -> Data? {
        guard let data, data.count <= richTextBytes else { return nil }
        return data
    }

    static func acceptsImage(_ data: Data, byteLimit: Int = imageBytes) -> Bool {
        guard data.count <= byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return false }
        // Division avoids overflow for malformed dimensions, before any decode.
        return width <= imagePixels / height
    }

    static func payloadBytes(of item: ClipItem) -> Int {
        let strings = [item.text, item.customTitle, item.sourceBundleID, item.sourceAppName]
        let stringBytes = strings.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
        let fileBytes = item.fileURLs.reduce(0) { $0 + $1.utf8.count }
        let richBytes = (item.rtfData?.count ?? 0) + (item.htmlData?.count ?? 0)
        return stringBytes + fileBytes + richBytes + 512 // Small fields and structural overhead.
    }

    static func retainedHistory(_ items: [ClipItem], countLimit: Int, cutoff: Date?,
                                imageSize: (ClipItem) -> Int) -> [ClipItem] {
        var retained: [ClipItem] = []
        var payload = 0
        var images = 0
        for item in items {
            if let cutoff, item.createdAt < cutoff { continue }
            let itemPayload = payloadBytes(of: item)
            let itemImage = max(0, imageSize(item))
            // A legacy oversized entry must not prevent retaining smaller clips.
            guard itemPayload <= historyPayloadBytes, itemImage <= historyImageBytes else { continue }
            guard retained.count < max(20, min(maximumHistoryCount, countLimit)),
                  payload + itemPayload <= historyPayloadBytes,
                  images + itemImage <= historyImageBytes else { break }
            retained.append(item)
            payload += itemPayload
            images += itemImage
        }
        return retained
    }
}
