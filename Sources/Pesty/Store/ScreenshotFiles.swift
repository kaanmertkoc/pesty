import Foundation

/// User-owned screenshot copies live outside the disposable history cache.
enum ScreenshotFiles {
    static func save(_ source: URL, in directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let created = try source.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss 'UTC'"
        let identifier = source.deletingPathExtension().lastPathComponent
        let stem = "Screenshot \(formatter.string(from: created)) \(identifier.prefix(8))"

        // Re-copying the same clip reuses its file. A user file at the same
        // name is never overwritten, even if it was edited after exporting.
        for suffix in 0..<1000 {
            let name = suffix == 0 ? stem : "\(stem) (\(suffix))"
            let destination = directory.appendingPathComponent(name).appendingPathExtension("png")
            if fm.fileExists(atPath: destination.path) {
                if fm.contentsEqual(atPath: source.path, andPath: destination.path) { return destination }
                continue
            }
            do {
                try fm.copyItem(at: source, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
