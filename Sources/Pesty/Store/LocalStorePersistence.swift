import Foundation

struct ClipboardSnapshot: Codable {
    var history: [ClipItem]
    var pinboards: [Pinboard]
}

/// Serial disk writes with at most one in-flight and one pending snapshot.
/// New captures replace the pending snapshot so slow storage cannot build an
/// unbounded queue of retained histories. Quit explicitly drains the queue.
final class LocalStorePersistence: @unchecked Sendable {
    private let url: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "Pesty.persistence", qos: .utility)
    private let lock = NSLock()
    private var pending: ClipboardSnapshot?
    private var draining = false
    private var persistedImages: Set<String> = []
    private var pendingImages: Set<String> = []
    private var writingImages: Set<String> = []
    private var lastError: String?
    var didSave: (@Sendable (String?) -> Void)?

    init(url: URL, maximumBytes: Int = ClipResourceLimits.maximumStoreBytes) {
        self.url = url
        self.maximumBytes = maximumBytes
    }

    func enqueue(_ snapshot: ClipboardSnapshot) {
        lock.lock()
        pending = snapshot
        pendingImages = Self.imageNames(in: snapshot)
        let shouldStart = !draining
        draining = true
        lock.unlock()
        if shouldStart { queue.async { self.drain() } }
    }

    func preserveImages(in snapshot: ClipboardSnapshot) {
        lock.lock()
        persistedImages = Self.imageNames(in: snapshot)
        lock.unlock()
    }

    func retainsImage(named name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return persistedImages.contains(name) || pendingImages.contains(name) || writingImages.contains(name)
    }

    private static func imageNames(in snapshot: ClipboardSnapshot) -> Set<String> {
        Set((snapshot.history + snapshot.pinboards.flatMap(\.items)).compactMap(\.imageFileName))
    }

    func flush(_ snapshot: ClipboardSnapshot) -> String? {
        enqueue(snapshot)
        return queue.sync { lastError }
    }

    private func drain() {
        while true {
            lock.lock()
            let snapshot = pending
            writingImages = pendingImages
            pendingImages = []
            pending = nil
            if snapshot == nil { draining = false }
            lock.unlock()
            guard let snapshot else { return }
            lastError = autoreleasepool {
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    guard data.count <= maximumBytes else {
                        return "History is too large to save. Remove some pinned clips or clear history; the previous saved file is preserved."
                    }
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    return nil
                } catch {
                    // Report the failure without logging any clipboard contents.
                    return "History could not be saved: \(error.localizedDescription)"
                }
            }
            lock.lock()
            if lastError == nil { persistedImages = writingImages }
            else { persistedImages.formUnion(writingImages) }
            writingImages = []
            lock.unlock()
            didSave?(lastError)
        }
    }
}
