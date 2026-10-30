import XCTest
import AppKit
@testable import Pesty

@MainActor
final class OfflineStorageTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPersistenceRoundTripAndPinboardIndependence() throws {
        let directory = try temporaryDirectory()
        let store = ClipboardStore(baseDirectory: directory)
        let item = ClipItem(type: .text, text: "local fixture")
        store.addCaptured(item)
        let board = store.addPinboard(name: "Saved")
        store.saveToPinboard(item, boardID: board.id)
        store.clearHistory()
        store.saveNow()
        XCTAssertNil(store.persistenceError)
        let reloaded = ClipboardStore(baseDirectory: directory)
        XCTAssertTrue(reloaded.history.isEmpty)
        XCTAssertEqual(reloaded.pinboards.first?.items.first?.text, "local fixture")
        XCTAssertNotEqual(reloaded.pinboards.first?.items.first?.id, item.id)
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("store.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptHistoryIsNotOverwrittenOnCaptureOrQuit() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("store.json")
        let original = Data("damaged history, preserve for recovery".utf8)
        try original.write(to: url)
        let store = ClipboardStore(baseDirectory: directory)
        XCTAssertNotNil(store.persistenceError)
        store.addCaptured(ClipItem(type: .text, text: "new capture"))
        store.saveNow()
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOrphanCleanupPreservesReferencedImages() throws {
        let directory = try temporaryDirectory()
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let kept = images.appendingPathComponent("kept.png")
        let orphan = images.appendingPathComponent("orphan.png")
        try Data([1]).write(to: kept)
        try Data([2]).write(to: orphan)
        let snapshot = ClipboardSnapshot(history: [ClipItem(type: .image, imageFileName: "kept.png")], pinboards: [])
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("store.json"))
        let store = ClipboardStore(baseDirectory: directory)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertNil(store.imageURL(for: ClipItem(type: .image, imageFileName: "../outside.png")))
    }

    func testWriterFlushPersistsNewestSnapshotAfterBurst() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("store.json")
        let writer = LocalStorePersistence(url: url)
        for index in 0..<500 {
            writer.enqueue(ClipboardSnapshot(history: [ClipItem(type: .text, text: "\(index)")], pinboards: []))
        }
        let newest = ClipboardSnapshot(history: [ClipItem(type: .text, text: "final")], pinboards: [])
        XCTAssertNil(writer.flush(newest))
        let loaded = try JSONDecoder().decode(ClipboardSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(loaded.history, newest.history)
    }

    func testWriteFailureIsReportedAndCanRecover() throws {
        let directory = try temporaryDirectory().appendingPathComponent("missing")
        let writer = LocalStorePersistence(url: directory.appendingPathComponent("store.json"))
        let snapshot = ClipboardSnapshot(history: [], pinboards: [])
        XCTAssertNotNil(writer.flush(snapshot))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertNil(writer.flush(snapshot))
    }

    func testHTMLOnlyClipFallsBackToPlainTextWithoutImportingHTML() throws {
        let clip = ClipItem(type: .text, text: "safe text",
                            htmlData: Data("<img src='https://example.com/tracker'><b>safe text</b>".utf8))
        XCTAssertFalse(FormatConverter.canConvert(clip))
        XCTAssertNil(FormatConverter.cleanedRTF(for: clip))
        XCTAssertNil(FormatConverter.markdown(for: clip))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        PasteService.copy(clip, format: .markdown, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "safe text")
        XCTAssertNil(pasteboard.data(forType: .html))
    }

    func testLocalRTFConversionStillWorks() throws {
        let rtf = try XCTUnwrap(NSAttributedString(string: "Local text").rtf(from: NSRange(location: 0, length: 10)))
        let clip = ClipItem(type: .richText, text: "Local text", rtfData: rtf)
        XCTAssertTrue(FormatConverter.canConvert(clip))
        XCTAssertEqual(FormatConverter.markdown(for: clip), "Local text")
        XCTAssertNotNil(FormatConverter.cleanedRTF(for: clip))
    }
    func testImageDeletionWaitsUntilCommittedSnapshotNoLongerNeedsIt() throws {
        let directory = try temporaryDirectory()
        let images = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let image = images.appendingPathComponent("saved.png")
        try Data([1]).write(to: image)
        let item = ClipItem(type: .image, imageFileName: "saved.png")
        let snapshot = ClipboardSnapshot(history: [item], pinboards: [])
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("store.json"))
        let store = ClipboardStore(baseDirectory: directory)
        store.delete(item, permanently: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        store.saveNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
    }

    func testEditorRejectsHTMLPaste() {
        let editor = OfflineTextView()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("<img src='https://example.com/tracker'>", forType: .html)
        XCTAssertFalse(editor.readablePasteboardTypes.contains(.html))
        XCTAssertFalse(editor.readSelection(from: pasteboard, type: .html))
        XCTAssertTrue(editor.string.isEmpty)
    }

    func testOversizedSavePreservesPreviousReadableSnapshot() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("store.json")
        let writer = LocalStorePersistence(url: url, maximumBytes: 1024)
        let small = ClipboardSnapshot(history: [ClipItem(type: .text, text: "saved")], pinboards: [])
        XCTAssertNil(writer.flush(small))
        let original = try Data(contentsOf: url)
        let huge = ClipboardSnapshot(history: [ClipItem(type: .text, text: String(repeating: "x", count: 2048))], pinboards: [])
        XCTAssertNotNil(writer.flush(huge))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNil(writer.flush(small))
    }

}
