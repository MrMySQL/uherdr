import AppKit
import ImageIO

@main struct MediaDecoderTests {
    static func main() {
        precondition(MediaDecoder.allows(width: 4_000, height: 4_000))
        precondition(!MediaDecoder.allows(width: 8_193, height: 1))
        precondition(!MediaDecoder.allows(width: 8_000, height: 8_000))
        precondition(!MediaDecoder.allows(width: Int.max, height: Int.max))
        precondition(!MediaDecoder.allows(width: 1, height: 0))
        precondition(MediaDecoder.image(Data()) == nil)
        precondition(MediaDecoder.pdf(Data()) == nil)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        precondition(MediaDecoder.image(data)?.size == CGSize(width: 2, height: 3))
        // A valid PDF whose page bounds exceed the rendering budget.
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 3_000, height: 100)
        let consumer = CGDataConsumer(data: bytes)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        precondition(MediaDecoder.pdf(bytes as Data) == nil)
        precondition(MediaDecoder.png(data) != nil && MediaDecoder.png(Data()) == nil)
        precondition(MediaDecoder.maxScale(CGSize(width: 4_000, height: 4_000)) == 1)
        precondition(MediaDecoder.maxScale(CGSize(width: 2, height: 3)) == 32)
        let pdfBytes = NSMutableData()
        var smallBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfBytes)!, mediaBox: &smallBox, nil)!
        pdfContext.beginPDFPage(nil)
        pdfContext.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 0, width: 2, height: 3))
        pdfContext.endPDFPage(); pdfContext.closePDF()
        precondition(MediaDecoder.pdf(pdfBytes as Data) != nil)
        for limits in [MediaDecoder.PDFLimits(pages: 0), MediaDecoder.PDFLimits(objects: 0),
                       MediaDecoder.PDFLimits(pixels: 1), MediaDecoder.PDFLimits(depth: 0)] {
            precondition(MediaDecoder.pdf(pdfBytes as Data, limits: limits) == nil, "PDF budget must reject before rendering")
        }
        var oversized = pdfBytes as Data
        let marker = Data("/Width 2".utf8)
        let replacement = Data("/Width 9000".utf8)
        guard let range = oversized.range(of: marker) else { preconditionFailure("PDF fixture lacks an image width") }
        oversized.replaceSubrange(range, with: replacement)
        // CoreGraphics repairs stale xref offsets; the image header is read before rendering.
        precondition(MediaDecoder.pdf(oversized) == nil)
        print("PASS: media dimension, pixel, invalid-input, bitmap decode and PDF page guards")
    }
}
