import AppKit
import XCTest
@testable import Pesty

@MainActor
final class ImagePathCopyTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    private func store() throws -> ClipboardStore {
        // Include spaces and Unicode to verify native path text, not a URL
        // with percent escapes or a shell-quoted string.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pesty path é \(UUID().uuidString)")
        let store = ClipboardStore(baseDirectory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return store
    }

    private func imageData(_ type: NSBitmapImageRep.FileType = .png,
                           width: Int = 4, height: Int = 3) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        bitmap.bitmapData?[0] = 255
        bitmap.bitmapData?[3] = 255
        if type == .tiff {
            return try XCTUnwrap(bitmap.tiffRepresentation(using: .none, factor: 0))
        }
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }

    private func capturePNG(in store: ClipboardStore) throws -> (ClipItem, Data) {
        let source = pasteboard()
        let png = try imageData()
        source.setData(png, forType: .png)
        XCTAssertNil(source.string(forType: .fileURL))
        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        store.addCaptured(item)
        return (item, png)
    }

    func testUnsavedClipboardImageCopiesExistingLocalPathAsText() throws {
        let store = try store()
        let (item, png) = try capturePNG(in: store)
        let destination = pasteboard()
        let previousChange = destination.changeCount
        let change = PasteService.copy(item, to: destination, store: store)
        let url = try XCTUnwrap(store.imageURL(for: item))
        XCTAssertNotEqual(change, previousChange)
        XCTAssertEqual(destination.string(forType: .string), url.path)
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertNil(destination.data(forType: .png))
        XCTAssertNil(destination.data(forType: .tiff))
        XCTAssertNil(destination.string(forType: .fileURL))
    }

    func testTIFFOnlyScreenshotGetsLocalPNGPath() throws {
        let store = try store()
        let source = pasteboard()
        source.setData(try imageData(.tiff), forType: .tiff)
        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        store.addCaptured(item)
        let destination = pasteboard()
        PasteService.copy(item, to: destination, store: store)
        let path = try XCTUnwrap(destination.string(forType: .string))
        XCTAssertTrue(path.hasSuffix(".png"))
        let png = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func testLargeTIFFScreenshotIsConvertedBeforeApplyingStoredImageLimit() throws {
        let store = try store()
        let source = pasteboard()
        // An ordinary Retina screenshot exceeds 16 MiB as an uncompressed
        // clipboard TIFF, even when its PNG is comfortably within the limit.
        let tiff = try imageData(.tiff, width: 2560, height: 1800)
        XCTAssertGreaterThan(tiff.count, ClipResourceLimits.imageBytes)
        source.setData(tiff, forType: .tiff)

        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        let url = try XCTUnwrap(store.imageURL(for: item))
        let png = try Data(contentsOf: url)
        XCTAssertTrue(ClipResourceLimits.acceptsImage(png))
        let restored = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(restored.pixelsWide, 2560)
        XCTAssertEqual(restored.pixelsHigh, 1800)
        XCTAssertEqual(restored.colorAt(x: 0, y: 0)?.redComponent, 1)

        let destination = pasteboard()
        PasteService.copy(item, format: .filePath, to: destination, store: store)
        XCTAssertEqual(destination.string(forType: .string), url.path)
        PasteService.copy(item, format: .original, to: destination, store: store)
        XCTAssertEqual(destination.data(forType: .png), png)
    }

    func testInvalidPNGRepresentationFallsBackToValidTIFF() throws {
        let store = try store()
        let source = pasteboard()
        source.setData(Data("invalid PNG".utf8), forType: .png)
        source.setData(try imageData(.tiff), forType: .tiff)

        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        let url = try XCTUnwrap(store.imageURL(for: item))
        XCTAssertTrue(ClipResourceLimits.acceptsImage(try Data(contentsOf: url)))
    }

    func testScreenshotCopyAutomaticallyAddsPasteablePathAndKeepsImageFormats() throws {
        let store = try store()
        let source = pasteboard()
        let png = try imageData()
        let tiff = try imageData(.tiff)
        source.setData(png, forType: .png)
        source.setData(tiff, forType: .tiff)
        let change = source.changeCount
        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        store.addCaptured(item)

        let ownChange = ClipboardMonitor.addImagePath(for: item, to: source, store: store,
                                                     ifUnchangedSince: change)

        XCTAssertEqual(ownChange, source.changeCount)
        let path = try XCTUnwrap(source.string(forType: .string))
        XCTAssertEqual(path, store.imageURL(for: item)?.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
        XCTAssertEqual(source.data(forType: .png), png)
        XCTAssertEqual(source.data(forType: .tiff), tiff)
        XCTAssertNil(ClipboardMonitor.addImagePath(for: item, to: source, store: store,
                                                   ifUnchangedSince: source.changeCount))
        XCTAssertEqual(source.changeCount, ownChange)
    }

    func testAutomaticScreenshotPathDoesNotOverwriteANewerCopy() throws {
        let store = try store()
        let source = pasteboard()
        source.setData(try imageData(), forType: .png)
        let change = source.changeCount
        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        store.addCaptured(item)
        source.clearContents()
        let newer = try imageData(.tiff)
        source.setData(newer, forType: .tiff)
        let newerChange = source.changeCount

        XCTAssertNil(ClipboardMonitor.addImagePath(for: item, to: source, store: store,
                                                   ifUnchangedSince: change))
        XCTAssertEqual(source.changeCount, newerChange)
        XCTAssertEqual(source.data(forType: .tiff), newer)
        XCTAssertNil(source.string(forType: .string))
    }

    func testAutomaticScreenshotPathPreservesExistingTextAndSkipsMissingImages() throws {
        let store = try store()
        let source = pasteboard()
        let png = try imageData()
        source.setData(png, forType: .png)
        source.setString("original image caption", forType: .string)
        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        store.addCaptured(item)
        let change = source.changeCount

        XCTAssertNil(ClipboardMonitor.addImagePath(for: item, to: source, store: store,
                                                   ifUnchangedSince: change))
        XCTAssertEqual(source.changeCount, change)
        XCTAssertEqual(source.string(forType: .string), "original image caption")

        source.clearContents()
        source.setData(png, forType: .png)
        try FileManager.default.removeItem(at: XCTUnwrap(store.imageURL(for: item)))
        let imageChange = source.changeCount
        XCTAssertNil(ClipboardMonitor.addImagePath(for: item, to: source, store: store,
                                                   ifUnchangedSince: imageChange))
        XCTAssertEqual(source.changeCount, imageChange)
        XCTAssertEqual(source.data(forType: .png), png)
        XCTAssertNil(source.string(forType: .string))
    }

    func testRepeatedScreenshotCopyUsesRetainedPathAfterDeduplication() throws {
        let store = try store()
        let (original, png) = try capturePNG(in: store)
        let source = pasteboard()
        source.setData(png, forType: .png)
        let change = source.changeCount
        let duplicate = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        XCTAssertNotEqual(original.imageFileName, duplicate.imageFileName)
        store.addCaptured(duplicate)
        store.saveNow()

        XCTAssertNotNil(ClipboardMonitor.addImagePath(for: duplicate, to: source, store: store,
                                                      ifUnchangedSince: change))
        XCTAssertEqual(source.string(forType: .string), store.imageURL(for: original)?.path)
        XCTAssertEqual(store.history.count, 1)
        let path = try XCTUnwrap(source.string(forType: .string))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
    }

    func testScreenshotCopiedByAnotherProcessGetsPasteablePath() throws {
        let store = try store()
        let source = pasteboard()
        let png = try imageData()
        let fixtureName = try XCTUnwrap(store.storeImageData(png))
        let fixtureURL = try XCTUnwrap(store.imageURL(for: ClipItem(type: .image, imageFileName: fixtureName)))
        let arguments = try XCTUnwrap(String(data: JSONEncoder().encode([source.name.rawValue, fixtureURL.path]),
                                            encoding: .utf8))
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        writer.arguments = ["-l", "JavaScript", "-e", """
            ObjC.import('AppKit');
            const args = \(arguments);
            const board = $.NSPasteboard.pasteboardWithName(args[0]);
            board.clearContents;
            if (!board.setDataForType($.NSData.dataWithContentsOfFile(args[1]), $.NSPasteboardTypePNG)) {
                throw new Error('Could not write screenshot fixture');
            }
            """]
        try writer.run()
        writer.waitUntilExit()
        XCTAssertEqual(writer.terminationStatus, 0)
        XCTAssertEqual(source.data(forType: .png), png)
        let change = source.changeCount
        let item = try XCTUnwrap(ClipboardMonitor.captureImage(from: source, into: store))
        store.addCaptured(item)

        XCTAssertNotNil(ClipboardMonitor.addImagePath(for: item, to: source, store: store,
                                                      ifUnchangedSince: change))
        XCTAssertEqual(source.string(forType: .string), store.imageURL(for: item)?.path)
        XCTAssertEqual(source.data(forType: .png), png)
    }

    func testExplicitOriginalStillCopiesImageBytes() throws {
        let store = try store()
        let (item, png) = try capturePNG(in: store)
        let destination = pasteboard()
        PasteService.copy(item, format: .original, to: destination, store: store)
        XCTAssertEqual(destination.data(forType: .png), png)
        XCTAssertNil(destination.string(forType: .string))
    }

    func testPlainTextQuickPasteUsesImagePath() throws {
        let store = try store()
        let (item, _) = try capturePNG(in: store)
        let destination = pasteboard()
        PasteService.copy(item, format: .plainText, to: destination, store: store)
        XCTAssertEqual(destination.string(forType: .string), store.imageURL(for: item)?.path)
        XCTAssertNil(destination.data(forType: .png))
    }

    func testMissingImageLeavesClipboardUntouched() throws {
        let store = try store()
        let item = ClipItem(type: .image, imageFileName: "missing.png")
        let destination = pasteboard()
        destination.setString("previous clipboard", forType: .string)
        let change = destination.changeCount
        for format: PasteFormat in [.filePath, .plainText, .original] {
            XCTAssertEqual(PasteService.copy(item, format: format, to: destination, store: store), change)
            XCTAssertEqual(destination.string(forType: .string), "previous clipboard")
        }
    }

    func testFileCopyUsesFullUnescapedPathsWithoutReadingTheFiles() {
        let paths = ["/nonexistent/Screenshot 2026-10-29 at 10.00.00 AM.png", "/nonexistent/é #2.png"]
        let item = ClipItem(type: .file, text: "Screenshot.png, é #2.png",
                            fileURLs: paths.map { URL(fileURLWithPath: $0).absoluteString })
        let destination = pasteboard()
        PasteService.copy(item, to: destination)
        XCTAssertEqual(destination.string(forType: .string), paths.joined(separator: "\n"))
        XCTAssertNil(destination.string(forType: .fileURL))
    }

    func testExplicitFileCopyPreservesFileURLAndUsesFullPathForTextFallback() {
        let url = URL(fileURLWithPath: "/nonexistent/Screenshot with spaces.png")
        let item = ClipItem(type: .file, text: url.lastPathComponent, fileURLs: [url.absoluteString])
        let destination = pasteboard()
        PasteService.copy(item, format: .original, to: destination)
        XCTAssertEqual(destination.string(forType: .string), url.path)
        let urls = destination.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls, [url])
    }

    func testPathSurvivesRelaunchAndRepeatedCopyDoesNotDuplicateThePNG() throws {
        let store = try store()
        let (item, _) = try capturePNG(in: store)
        store.saveNow()
        let reloaded = ClipboardStore(baseDirectory: store.dataDirectory)
        let restored = try XCTUnwrap(reloaded.history.first)
        let destination = pasteboard()
        for _ in 0..<3 { PasteService.copy(restored, to: destination, store: reloaded) }
        XCTAssertEqual(destination.string(forType: .string), store.imageURL(for: item)?.path)
        let images = try FileManager.default.contentsOfDirectory(
            at: store.dataDirectory.appendingPathComponent("images"), includingPropertiesForKeys: nil)
        XCTAssertEqual(images.count, 1)
    }

    func testTextCopyRemainsTextAndCannotBeCopiedAsAFilePath() {
        let item = ClipItem(type: .text, text: "ordinary text")
        let destination = pasteboard()
        PasteService.copy(item, to: destination)
        XCTAssertEqual(destination.string(forType: .string), "ordinary text")
        let change = destination.changeCount
        XCTAssertEqual(PasteService.copy(item, format: .filePath, to: destination), change)
    }
    func testDefaultPasteInsertsImagePathWithoutExtraModifier() throws {
        let store = try store()
        let (item, _) = try capturePNG(in: store)
        let destination = pasteboard()
        let monitor = ClipboardMonitor()
        PasteService.paste(item, into: nil, monitor: monitor, to: destination, store: store)
        XCTAssertEqual(destination.string(forType: .string), store.imageURL(for: item)?.path)
        XCTAssertNil(destination.data(forType: .png))
        XCTAssertNil(destination.data(forType: .tiff))
        XCTAssertEqual(monitor.suppressUntilChangeCount, destination.changeCount)
    }

    func testExplicitOriginalPasteStillInsertsImageBytes() throws {
        let store = try store()
        let (item, png) = try capturePNG(in: store)
        let destination = pasteboard()
        PasteService.paste(item, into: nil, monitor: ClipboardMonitor(), format: .original,
                           to: destination, store: store)
        XCTAssertEqual(destination.data(forType: .png), png)
        XCTAssertNil(destination.string(forType: .string))
    }

    func testDefaultPasteInsertsFilePathAsText() {
        let url = URL(fileURLWithPath: "/nonexistent/Screenshot with spaces.png")
        let item = ClipItem(type: .file, text: url.lastPathComponent, fileURLs: [url.absoluteString])
        let destination = pasteboard()
        PasteService.paste(item, into: nil, monitor: ClipboardMonitor(), to: destination)
        XCTAssertEqual(destination.string(forType: .string), url.path)
        XCTAssertNil(destination.string(forType: .fileURL))
    }

    func testDefaultTextPastePreservesFormatting() throws {
        let text = "formatted text"
        let rtf = try XCTUnwrap(NSAttributedString(string: text).rtf(from: NSRange(location: 0, length: text.count)))
        let item = ClipItem(type: .richText, text: text, rtfData: rtf)
        let destination = pasteboard()
        PasteService.paste(item, into: nil, monitor: ClipboardMonitor(), to: destination)
        XCTAssertEqual(destination.string(forType: .string), text)
        XCTAssertEqual(destination.data(forType: .rtf), rtf)
    }

}
