import XCTest
import AppKit
@testable import Pesty

final class ClipResourceLimitsTests: XCTestCase {
    func testTextLimitCountsUTF8Bytes() {
        XCTAssertTrue(ClipResourceLimits.acceptsText(String(repeating: "a", count: ClipResourceLimits.textBytes)))
        XCTAssertFalse(ClipResourceLimits.acceptsText(String(repeating: "a", count: ClipResourceLimits.textBytes + 1)))
        XCTAssertFalse(ClipResourceLimits.acceptsText(String(repeating: "é", count: ClipResourceLimits.textBytes)))
    }

    func testOversizedFormattingIsDropped() {
        XCTAssertEqual(ClipResourceLimits.boundedRTF(Data([1, 2])), Data([1, 2]))
        XCTAssertNil(ClipResourceLimits.boundedRTF(Data(count: ClipResourceLimits.richTextBytes + 1)))
    }

    func testImageValidationBeforeDecode() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertTrue(ClipResourceLimits.acceptsImage(png))
        XCTAssertFalse(ClipResourceLimits.acceptsImage(Data("invalid image".utf8)))
        XCTAssertFalse(ClipResourceLimits.acceptsImage(Data(count: ClipResourceLimits.imageBytes + 1)))
        var giantHeader = png
        giantHeader.replaceSubrange(16..<24, with: [0x7f, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff])
        XCTAssertFalse(ClipResourceLimits.acceptsImage(giantHeader))
    }

    func testHistoryBudgetsKeepNewestPrefix() {
        let items = (0..<50).map { ClipItem(type: .text, text: "\($0)" + String(repeating: "x", count: 1024 * 1024)) }
        let retained = ClipResourceLimits.retainedHistory(items, countLimit: 500, cutoff: nil, imageSize: { _ in 0 })
        XCTAssertLessThan(retained.count, items.count)
        XCTAssertEqual(retained, Array(items.prefix(retained.count)))
        XCTAssertLessThanOrEqual(retained.reduce(0) { $0 + ClipResourceLimits.payloadBytes(of: $1) }, ClipResourceLimits.historyPayloadBytes)
        let images = ClipResourceLimits.retainedHistory(items, countLimit: 500, cutoff: nil, imageSize: { _ in 16 * 1024 * 1024 })
        XCTAssertEqual(images.count, 16)
    }

    func testCountAgeAndLegacyOversizedEntry() {
        let recent = (0..<25).map { ClipItem(type: .text, text: "\($0)", createdAt: Date(timeIntervalSince1970: 200)) }
        let old = ClipItem(type: .text, text: "old", createdAt: Date(timeIntervalSince1970: 0))
        let retained = ClipResourceLimits.retainedHistory(recent + [old], countLimit: 20,
            cutoff: Date(timeIntervalSince1970: 100), imageSize: { _ in 0 })
        XCTAssertEqual(retained, Array(recent.prefix(20)))
        let giant = ClipItem(type: .image, imageFileName: "legacy.png")
        let smaller = ClipResourceLimits.retainedHistory([giant] + recent, countLimit: 500, cutoff: nil,
            imageSize: { $0.type == .image ? ClipResourceLimits.historyImageBytes + 1 : 0 })
        XCTAssertEqual(smaller, recent)
    }
}
