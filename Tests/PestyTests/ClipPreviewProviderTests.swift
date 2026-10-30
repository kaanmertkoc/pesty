import XCTest
@testable import Pesty

@MainActor
final class ClipPreviewProviderTests: XCTestCase {
    func testOnlyCapturedImagesArePreviewed() async {
        for path in ["file:///tmp/shot.png", "file:///Volumes/server/remote.jpg", "https://example.com/image.png"] {
            let file = ClipItem(type: .file, fileURLs: [path])
            XCTAssertFalse(ClipPreviewProvider.showsImage(file))
            let image = await ClipPreviewProvider.image(for: file, scale: 2)
            XCTAssertNil(image)
        }
        XCTAssertTrue(ClipPreviewProvider.showsImage(ClipItem(type: .image, imageFileName: "x.png")))
    }

    func testFileIconsDoNotDependOnAccessToOriginalFile() async {
        // This path must never be stat'ed or passed to a thumbnail provider.
        let file = ClipItem(type: .file, fileURLs: ["file:///nonexistent/\(UUID().uuidString).pdf"])
        let info = await ClipPreviewProvider.fileInfo(for: file)
        XCTAssertNotNil(info?.icon)
        XCTAssertEqual(info?.isMissing, false)
        let text = await ClipPreviewProvider.fileInfo(for: ClipItem(type: .text, text: "x"))
        XCTAssertNil(text)
    }
}
