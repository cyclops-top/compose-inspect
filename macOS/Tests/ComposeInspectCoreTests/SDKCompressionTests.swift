import XCTest
@testable import ComposeInspectCore

final class SDKCompressionTests: XCTestCase {
    private let gzip = Data(base64Encoded: "H4sIAAAAAAAC/6tWykjNyclXslIqzy/KSVGq5QIAkO3bwxIAAAA=")!

    func testDecodesGzipWithChecksumAndStripsFrameNewline() throws {
        XCTAssertEqual(String(decoding: try SDKCompressedResponse.decode(gzip, maxBytes: 100), as: UTF8.self), "{\"hello\":\"world\"}")
    }

    func testRejectsCorruptionTruncationExtraMembersAndExpansionBeyondLimit() {
        var corrupted = gzip
        corrupted[corrupted.count - 8] ^= 1
        for data in [corrupted, Data(gzip.dropLast()), gzip + gzip, Data()] {
            XCTAssertThrowsError(try SDKCompressedResponse.decode(data, maxBytes: 100))
        }
        XCTAssertThrowsError(try SDKCompressedResponse.decode(gzip, maxBytes: 17))
    }

    func testLengthHeaderWaitsForAllBytesAndRejectsInvalidSizes() throws {
        XCTAssertNil(try SDKCompressedResponse.frameLength(Data([0, 0, 0]), maxBytes: 100))
        XCTAssertEqual(try SDKCompressedResponse.frameLength(Data([0, 0, 0, 35]), maxBytes: 100), 39)
        XCTAssertThrowsError(try SDKCompressedResponse.frameLength(Data([0, 0, 0, 0]), maxBytes: 100))
        XCTAssertThrowsError(try SDKCompressedResponse.frameLength(Data([255, 255, 255, 255]), maxBytes: 100))
    }
}
