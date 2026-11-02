import AppKit
import XCTest
@testable import Pesty

@MainActor
final class ScreenshotFolderTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pesty screenshots é \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 127, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func capture(_ data: Data, in store: ClipboardStore) throws -> ClipItem {
        let board = pasteboard()
        board.setData(data, forType: .png)
        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: board, into: store))
        store.addCaptured(item)
        return item
    }

    func testCaptureAndCopyUseChosenFolderWithoutExposingHistoryPath() throws {
        let root = try directory()
        let folder = root.appendingPathComponent("screenshots")
        let store = ClipboardStore(baseDirectory: root.appendingPathComponent("history"),
                                   screenshotDirectory: { folder })
        let data = try png()
        let source = pasteboard()
        source.setData(data, forType: .png)
        let change = source.changeCount
        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        store.addCaptured(item)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)

        XCTAssertNotNil(ClipboardMonitor.addImagePath(for: item, to: source, store: store,
                                                      ifUnchangedSince: change))
        let path = try XCTUnwrap(source.string(forType: .string))
        let exported = URL(fileURLWithPath: path)
        XCTAssertEqual(exported.deletingLastPathComponent().path, folder.path)
        XCTAssertTrue(exported.lastPathComponent.hasPrefix("Screenshot "))
        XCTAssertEqual(try Data(contentsOf: exported), data)
        XCTAssertEqual(source.data(forType: .png), data)
        XCTAssertNotEqual(store.imageURL(for: item)?.path, path)
        XCTAssertNil(store.screenshotExportError)

        let destination = pasteboard()
        for format: PasteFormat in [.filePath, .plainText] {
            PasteService.copy(item, format: format, to: destination, store: store)
            XCTAssertEqual(destination.string(forType: .string), path)
        }
        PasteService.copy(item, format: .original, to: destination, store: store)
        XCTAssertEqual(destination.data(forType: .png), data)
    }

    func testRepeatedCopyAndRelaunchReuseScreenshotAndHistoryCleanupKeepsIt() throws {
        let root = try directory()
        let history = root.appendingPathComponent("history")
        let folder = root.appendingPathComponent("screenshots")
        let store = ClipboardStore(baseDirectory: history, screenshotDirectory: { folder })
        let data = try png()
        let item = try capture(data, in: store)
        let exported = try XCTUnwrap(store.imagePathURL(for: item))
        _ = try capture(data, in: store)
        store.saveNow()

        let reloaded = ClipboardStore(baseDirectory: history, screenshotDirectory: { folder })
        let restored = try XCTUnwrap(reloaded.history.first)
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.imagePathURL(for: restored), exported)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        reloaded.clearHistory()
        reloaded.saveNow()
        XCTAssertTrue(reloaded.history.isEmpty)
        XCTAssertEqual(try Data(contentsOf: exported), data)
    }

    func testChangingFolderExportsIntoNewFolderWithoutRemovingPreviousFiles() throws {
        let root = try directory()
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        var chosen: URL? = first
        let store = ClipboardStore(baseDirectory: root.appendingPathComponent("history"),
                                   screenshotDirectory: { chosen })
        let data = try png()
        let item = try capture(data, in: store)
        let oldURL = try XCTUnwrap(store.imagePathURL(for: item))
        chosen = second
        let newURL = try XCTUnwrap(store.imagePathURL(for: item))
        XCTAssertEqual(newURL.deletingLastPathComponent().path, second.path)
        XCTAssertEqual(try Data(contentsOf: oldURL), data)
        XCTAssertEqual(try Data(contentsOf: newURL), data)
        chosen = nil
        XCTAssertEqual(store.imagePathURL(for: item), store.imageURL(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testExportNeverOverwritesAnEditedScreenshot() throws {
        let root = try directory()
        let folder = root.appendingPathComponent("screenshots")
        let store = ClipboardStore(baseDirectory: root.appendingPathComponent("history"),
                                   screenshotDirectory: { folder })
        let data = try png()
        let item = try capture(data, in: store)
        let originalURL = try XCTUnwrap(store.imagePathURL(for: item))
        let edited = Data("user edited this file".utf8)
        try edited.write(to: originalURL)
        let newURL = try XCTUnwrap(store.imagePathURL(for: item))
        XCTAssertNotEqual(originalURL, newURL)
        XCTAssertEqual(try Data(contentsOf: originalURL), edited)
        XCTAssertEqual(try Data(contentsOf: newURL), data)
        XCTAssertEqual(store.imagePathURL(for: item), newURL)
    }

    func testUnavailableFolderPreservesClipboardAndHistoryThenRecovers() throws {
        let root = try directory()
        let blocked = root.appendingPathComponent("not a directory")
        try Data("existing file".utf8).write(to: blocked)
        var chosen = blocked
        let store = ClipboardStore(baseDirectory: root.appendingPathComponent("history"),
                                   screenshotDirectory: { chosen })
        let data = try png()
        let item = try capture(data, in: store)
        XCTAssertNotNil(store.screenshotExportError)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.imageURL(for: item))), data)
        let destination = pasteboard()
        destination.setString("keep clipboard", forType: .string)
        let change = destination.changeCount
        XCTAssertEqual(PasteService.copy(item, to: destination, store: store), change)
        XCTAssertEqual(destination.string(forType: .string), "keep clipboard")
        chosen = root.appendingPathComponent("recovered")
        XCTAssertNotNil(store.imagePathURL(for: item))
        XCTAssertNil(store.screenshotExportError)
    }

    func testHistoryDirectoryAndSymlinksIntoItCannotBeExportFolders() throws {
        let root = try directory()
        let history = root.appendingPathComponent("history")
        let images = history.appendingPathComponent("images")
        let store = ClipboardStore(baseDirectory: history, screenshotDirectory: { images })
        XCTAssertFalse(store.allowsScreenshotFolder(history))
        XCTAssertFalse(store.allowsScreenshotFolder(images))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: images)
        XCTAssertFalse(store.allowsScreenshotFolder(link))
        let item = try capture(png(), in: store)
        XCTAssertNil(store.imagePathURL(for: item))
        XCTAssertNotNil(store.screenshotExportError)
        XCTAssertTrue(store.allowsScreenshotFolder(root.appendingPathComponent("screenshots")))
    }
}
