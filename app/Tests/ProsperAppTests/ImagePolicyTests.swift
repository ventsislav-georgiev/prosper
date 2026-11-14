import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ProsperApp

/// A width x height PNG, drawn in memory (shared with TextViewerWindowTests).
func pngData(width: Int, height: Int) throws -> Data {
    let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(ctx.makeImage())
    let data = NSMutableData()
    let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    return data as Data
}

/// #1118 (design #1105 D7, section 3 C2 and N5): which images a document may draw. Files are fakes
/// in a tempDir(); nothing is fetched (a remote source is refused before any call).
final class ImagePolicyTests: XCTestCase {

    private var dir: URL!
    private var doc: URL { dir.appendingPathComponent("doc.md") }

    override func setUpWithError() throws {
        dir = tempDir("tv-img")
        try Data("# doc\n".utf8).write(to: doc)
        try pngData(width: 8, height: 8).write(to: dir.appendingPathComponent("pic.png"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        try pngData(width: 8, height: 8).write(to: dir.appendingPathComponent("sub/pic2.png"))
    }

    private func link(_ name: String, to target: String) throws {
        XCTAssertEqual(symlink(target, dir.appendingPathComponent(name).path), 0, name)
    }

    private func url(_ s: String) throws -> URL { try XCTUnwrap(URL(string: s), s) }

    /// C2: an image in the document's folder or below, through an in-tree symlink too, loads.
    func testInsideTreeAllowed() throws {
        let canonical = try XCTUnwrap(realpath(dir.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        try link("sub/in.png", to: "../pic.png")
        try link("abs.png", to: canonical + "/sub/pic2.png")
        try link("subdir", to: "sub")
        for src in ["pic.png", "./pic.png", "sub/pic2.png", "sub/../pic.png", "sub/in.png", "abs.png", "subdir/pic2.png",
                    "file://" + dir.path + "/pic.png", dir.path + "/sub/pic2.png", canonical + "/pic.png"] {
            let u = try url(src)   // the tempDir path has no character to escape
            XCTAssertNotNil(ImagePolicy.inside(u, document: doc), src)
            let image = ImagePolicy.load(u, document: doc, maxPixelSize: 64)
            XCTAssertTrue(image?.width == 8, src)
        }
    }

    /// N5: nothing outside the folder tree, by any spelling, and nothing remote.
    func testOutsideTreeRefused() throws {
        let other = tempDir("tv-img-out")
        try pngData(width: 8, height: 8).write(to: other.appendingPathComponent("out.png"))
        try link("out-abs.png", to: other.path + "/out.png")
        try link("out-rel.png", to: "../" + other.lastPathComponent + "/out.png")
        try link("sub/up.png", to: "../../" + other.lastPathComponent + "/out.png")
        try link("loop.png", to: "loop.png")
        // A canonical absolute link out of the tree whose last name also exists inside it: refused, never
        // re-read as the in-tree file.
        let otherCanonical = try XCTUnwrap(realpath(other.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        try pngData(width: 4, height: 4).write(to: dir.appendingPathComponent("out.png"))
        try link("esc.png", to: otherCanonical + "/out.png")
        for src in ["../" + other.lastPathComponent + "/out.png", "sub/../../" + other.lastPathComponent + "/out.png",
                    "out-abs.png", "out-rel.png", "sub/up.png", "loop.png", "esc.png", other.path + "/out.png",
                    "/net/example/x.png", "/etc/hosts", "missing.png",
                    "https://example.com/pic.png", "//example.com/pic.png", "file://example.com" + dir.path + "/pic.png",
                    "data:image/png;base64,iVBORw0KGgo=", "sub%2Fpic2.png", "pic%0A.png"] {
            guard let u = URL(string: src) else { continue }
            XCTAssertTrue(ImagePolicy.inside(u, document: doc) == nil, src)
            XCTAssertTrue(ImagePolicy.load(u, document: doc, maxPixelSize: 64) == nil, src)
        }
        XCTAssertFalse(ImagePolicy.isLocal(try url("https://example.com/a.png")))
        XCTAssertFalse(ImagePolicy.isLocal(try url("data:image/png;base64,AAAA")))
        XCTAssertTrue(ImagePolicy.isLocal(try url("a.png")))
    }

    /// A FIFO never blocks the open and is refused; so is a folder named like an image.
    func testNotARegularFileRefused() throws {
        XCTAssertEqual(mkfifo(dir.appendingPathComponent("fifo.png").path, 0o600), 0)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("dir.png"), withIntermediateDirectories: false)
        XCTAssertTrue(ImagePolicy.load(try url("fifo.png"), document: doc, maxPixelSize: 64) == nil)
        XCTAssertTrue(ImagePolicy.load(try url("dir.png"), document: doc, maxPixelSize: 64) == nil)
    }

    /// D7: at most 20 MiB on disk. A valid PNG padded past the cap is refused; the same PNG loads.
    func testOverTwentyMiBRefused() throws {
        var big = try pngData(width: 8, height: 8)
        try big.write(to: dir.appendingPathComponent("small.png"))
        big.append(Data(count: ImagePolicy.maxBytes + 1 - big.count))
        XCTAssertEqual(big.count, ImagePolicy.maxBytes + 1)
        try big.write(to: dir.appendingPathComponent("big.png"))
        XCTAssertTrue(ImagePolicy.load(try url("small.png"), document: doc, maxPixelSize: 64)?.width == 8)
        XCTAssertTrue(ImagePolicy.load(try url("big.png"), document: doc, maxPixelSize: 64) == nil)
    }

    /// D7: raster types only, whatever the name says: a PDF and an SVG named .png are refused.
    func testNotRasterRefused() throws {
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 8, height: 8)
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdf))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.fill(box)
        ctx.endPDFPage()
        ctx.closePDF()
        try (pdf as Data).write(to: dir.appendingPathComponent("doc.png"))
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>"#
        try Data(svg.utf8).write(to: dir.appendingPathComponent("vec.png"))
        XCTAssertTrue(ImagePolicy.load(try url("doc.png"), document: doc, maxPixelSize: 64) == nil, "PDF")
        XCTAssertTrue(ImagePolicy.load(try url("vec.png"), document: doc, maxPixelSize: 64) == nil, "SVG")
        // An icon file decodes to pixels with a width and height, so only the type allowlist refuses it.
        let image = try XCTUnwrap(ImagePolicy.decode(try pngData(width: 16, height: 16), maxPixelSize: 64))
        let ico = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(ico, "com.microsoft.ico" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(ico, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "the icon itself decodes")
        try (ico as Data).write(to: dir.appendingPathComponent("icon.png"))
        XCTAssertTrue(ImagePolicy.load(try url("icon.png"), document: doc, maxPixelSize: 64) == nil, "ICO")
    }

    /// The header's width x height is checked before any decode, and the thumbnail is capped.
    func testPixelCapAndThumbnailSize() throws {
        let png = try pngData(width: 20, height: 20)
        XCTAssertTrue(ImagePolicy.decode(png, maxPixelSize: 64, maxSourcePixels: 399) == nil, "400 pixels over a cap of 399")
        XCTAssertTrue(ImagePolicy.decode(png, maxPixelSize: 64, maxSourcePixels: 400)?.width == 20)
        let wide = try XCTUnwrap(ImagePolicy.decode(try pngData(width: 400, height: 10), maxPixelSize: 64))
        XCTAssertLessThanOrEqual(max(wide.width, wide.height), 64)
        XCTAssertTrue(ImagePolicy.decode(Data(), maxPixelSize: 64) == nil)
        XCTAssertTrue(ImagePolicy.decode(Data("not an image".utf8), maxPixelSize: 64) == nil)
    }
}
