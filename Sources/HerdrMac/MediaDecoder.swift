import AppKit
import ImageIO
import PDFKit

/// Preflight dimensions without decoding pixels; only the first image frame is
/// decoded, into a bounded bitmap. Never hand compressed data to NSImage.
enum MediaDecoder {
    static let maxSide = 8_192
    static let maxPixels = 16_000_000
    static let failure = "The file is invalid or exceeds the preview limits (8,192 pixels per side, 16 million pixels per image; PDFs: 200 pages and 1,024 points per page)."

    static func allows(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxSide && height <= maxSide && width <= maxPixels / height
    }

    static func image(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              allows(width: width, height: height),
              let bitmap = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: bitmap, size: CGSize(width: width, height: height))
    }

    static func maxScale(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(32, CGFloat(maxSide) / size.width, CGFloat(maxSide) / size.height,
                   sqrt(CGFloat(maxPixels) / (size.width * size.height)))
    }

    /// Flatten web assets to the same bounded first frame; WebKit must not
    /// decode the original animation or a different, larger frame.
    static func png(_ data: Data) -> Data? {
        guard let image = image(data), let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
    }

    struct PDFLimits {
        var pages = 200
        var objects = 10_000
        var pixels = 32_000_000
        var depth = 16
    }

    static func pdf(_ data: Data, limits: PDFLimits = PDFLimits()) -> PDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
              !pdf.isEncrypted, pdf.numberOfPages > 0, pdf.numberOfPages <= limits.pages else { return nil }
        let scan = PDFResources(limits: limits)
        for number in 1...pdf.numberOfPages {
            guard let page = pdf.page(at: number), let dictionary = page.dictionary else { return nil }
            for box in [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                let bounds = page.getBoxRect(box)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                      bounds.width <= 1_024, bounds.height <= 1_024 else { return nil }
            }
            // PDF page resources may be inherited from the page tree.
            var ancestor: CGPDFDictionaryRef? = dictionary
            for depth in 0..<16 {
                guard let current = ancestor else { break }
                var resources: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                    scan.resources(resources, depth: 0)
                    break
                }
                var parent: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(current, "Parent", &parent)
                ancestor = parent
                if depth == 15 && parent != nil { scan.valid = false }
            }
            guard scan.valid else { return nil }
        }
        return PDFDocument(data: data)
    }

    private final class PDFResources {
        var valid = true
        var remainingObjects: Int
        var remainingPixels: Int
        let maximumDepth: Int
        init(limits: PDFLimits) {
            remainingObjects = limits.objects; remainingPixels = limits.pixels; maximumDepth = limits.depth
        }
        func resources(_ dictionary: CGPDFDictionaryRef, depth: Int) {
            guard depth < maximumDepth else { valid = false; return }
            var objects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "XObject", &objects), let objects else { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            // The callback cannot capture Swift state; depth is bounded by the
            // object budget too, with resource recursion handled below.
            CGPDFDictionaryApplyFunction(objects, { _, object, info in
                guard let info else { return }
                let scan = Unmanaged<PDFResources>.fromOpaque(info).takeUnretainedValue()
                scan.object(object)
            }, context)
        }
        private func object(_ object: CGPDFObjectRef) {
            guard valid, remainingObjects > 0 else { valid = false; return }
            remainingObjects -= 1
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return }
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { valid = false; return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { valid = false; return }
            if String(cString: subtype) == "Image" {
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
                      MediaDecoder.allows(width: width, height: height), width <= remainingPixels / height else { valid = false; return }
                remainingPixels -= width * height
                // Soft masks are images too.
                for name in ["SMask", "Mask"] {
                    var mask: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(dictionary, name, &mask), let mask { self.object(mask) }
                }
            } else {
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                    // A separate recursion counter prevents cyclic Forms from
                    // exhausting the stack before the object count runs out.
                    nesting += 1
                    resources(nested, depth: nesting)
                    nesting -= 1
                }
            }
        }
        private var nesting = 0
    }
}
