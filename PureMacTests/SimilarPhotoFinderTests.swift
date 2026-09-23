import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Qpure

final class SimilarPhotoFinderTests: XCTestCase {
    private var temporaryFolders: [URL] = []

    override func tearDownWithError() throws {
        for folder in temporaryFolders {
            try? FileManager.default.removeItem(at: folder)
        }
        temporaryFolders = []
        try super.tearDownWithError()
    }

    func testScanGroupsVisuallySimilarImagesAndLeavesDifferentImageOut() async throws {
        let folder = try makeTemporaryFolder()
        try writePatternImage(to: folder.appendingPathComponent("first.png"), variation: 0)
        try writePatternImage(to: folder.appendingPathComponent("second.png"), variation: 1)
        try writePatternImage(to: folder.appendingPathComponent("different.png"), variation: 2)

        let result = try await SimilarPhotoFinder().scan(folder: folder)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].photos.map(\.url.lastPathComponent)), ["first.png", "second.png"])
        XCTAssertEqual(result.photosAnalyzed, 3)
        XCTAssertFalse(result.isPartial)
    }

    func testScanSkipsSymbolicLinksPackagesAndCloudPlaceholderFiles() async throws {
        let folder = try makeTemporaryFolder()
        let first = folder.appendingPathComponent("first.png")
        let second = folder.appendingPathComponent("second.png")
        let symlink = folder.appendingPathComponent("linked.png")
        let package = folder.appendingPathComponent("Hidden.app", isDirectory: true)
        try writePatternImage(to: first, variation: 0)
        try writePatternImage(to: second, variation: 0)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: first)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writePatternImage(to: package.appendingPathComponent("inside.png"), variation: 0)
        try Data("placeholder".utf8).write(to: folder.appendingPathComponent("pending.icloud"))

        let result = try await SimilarPhotoFinder().scan(folder: folder)

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0].photos.map(\.url.lastPathComponent)), ["first.png", "second.png"])
        XCTAssertEqual(result.photosAnalyzed, 2)
        XCTAssertGreaterThanOrEqual(result.skippedItems, 3)
    }

    func testPhotoLimitProducesExplicitPartialResult() async throws {
        let folder = try makeTemporaryFolder()
        try writePatternImage(to: folder.appendingPathComponent("one.png"), variation: 0)
        try writePatternImage(to: folder.appendingPathComponent("two.png"), variation: 0)
        try writePatternImage(to: folder.appendingPathComponent("three.png"), variation: 0)
        let finder = SimilarPhotoFinder(limits: SimilarPhotoScanLimits(maxPhotos: 2, maxEntries: 100))

        let result = try await finder.scan(folder: folder)

        XCTAssertEqual(result.photosAnalyzed, 2)
        XCTAssertTrue(result.photoLimitReached)
        XCTAssertTrue(result.isPartial)
    }

    func testCancelledScanThrowsCancellationError() async throws {
        let folder = try makeTemporaryFolder()
        for index in 0..<20 {
            try writePatternImage(to: folder.appendingPathComponent("image-\(index).png"), variation: 0)
        }
        let finder = SimilarPhotoFinder()
        let task = Task {
            try await finder.scan(folder: folder)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PureMac-SimilarPhotoFinderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        temporaryFolders.append(folder)
        return folder
    }

    private func writePatternImage(to url: URL, variation: Int) throws {
        let width = 96
        let height = 72
        var pixels = [UInt8](repeating: 255, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                switch variation {
                case 2:
                    let light = ((x / 8) + (y / 8)).isMultiple(of: 2)
                    pixels[offset] = light ? 245 : 20
                    pixels[offset + 1] = light ? 210 : 35
                    pixels[offset + 2] = light ? 40 : 210
                default:
                    pixels[offset] = UInt8(min(255, 35 + x * 2))
                    pixels[offset + 1] = UInt8(min(255, 55 + y * 2))
                    pixels[offset + 2] = 145
                    if variation == 1 && x > 82 && y > 60 {
                        pixels[offset] = 210
                        pixels[offset + 1] = 205
                        pixels[offset + 2] = 190
                    }
                }
                pixels[offset + 3] = 255
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            return XCTFail("Could not create test image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
