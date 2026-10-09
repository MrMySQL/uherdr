import AppKit
import PDFKit
import SwiftUI
import WebKit
import HerdrCore
import HerdrMarkdown

// MARK: - Images (frame 16)

/// A read-only image tab: fitted to the tab, zoomable, with its size and type.
struct ImageViewerView: View {
    let name: String
    let data: Data
    @State private var zoom: CGFloat? = nil // nil: fit
    @State private var fitted: CGFloat = 1

    var body: some View {
        if let image = MediaDecoder.image(data) {
            let pixels = Self.pixelSize(image)
            let scale = zoom ?? fitted
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    Text("\(Int(pixels.width)) × \(Int(pixels.height)) · \(Self.type(name)) · \(EditorHostView.size(data.count))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Button { zoom = max(0.05, scale / 1.5) } label: { Image(systemName: "minus") }.help("Zoom out").accessibilityLabel("Zoom out")
                    Text("\(Int((scale * 100).rounded()))%").font(.system(size: 11, weight: .medium)).monospacedDigit().frame(minWidth: 44)
                        .accessibilityLabel("Zoom \(Int((scale * 100).rounded())) percent")
                    Button { zoom = min(32, scale * 1.5) } label: { Image(systemName: "plus") }.help("Zoom in").accessibilityLabel("Zoom in")
                    Button("Fit") { zoom = nil }.disabled(zoom == nil).help("Fit the image to the tab")
                    Button("Actual Size") { zoom = 1 }.disabled(scale == 1)
                }
                .controlSize(.small)
                .padding(.horizontal, 12).frame(height: 30)
                Divider()
                GeometryReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(scale >= 2 ? .none : .high)
                            .frame(width: pixels.width * scale, height: pixels.height * scale)
                            .background(Checkerboard())
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                    }
                    .onAppear { fitted = Self.fitScale(pixels, in: proxy.size) }
                    .onChange(of: proxy.size) { _, size in fitted = Self.fitScale(pixels, in: size) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Image \(name), \(Int(pixels.width)) by \(Int(pixels.height))")
        } else {
            CantShowView(title: "Can't show this image", detail: MediaDecoder.failure)
        }
    }

    /// Bitmap images report pixels; vector images (SVG, PDF) their points.
    static func pixelSize(_ image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    /// Fitted to the tab: large images shrink, small ones (icons) grow, up to
    /// 400% so they stay recognizable rather than a blur of pixels.
    static func fitScale(_ size: CGSize, in area: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0, area.width > 40, area.height > 40 else { return 1 }
        return min(4, (area.width - 40) / size.width, (area.height - 40) / size.height)
    }

    static func type(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext == "JPG" ? "JPEG" : ext
    }
}

/// Shows transparency.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color.primary.opacity(0.06)))
                }
            }
        }
    }
}

// MARK: - PDFs (frame 17)

struct PDFViewerView: View {
    let name: String
    let data: Data
    @State private var page = 1
    @State private var pages = 0
    @State private var command: PDFCommand?

    enum PDFCommand: Equatable { case zoomIn, zoomOut, fitWidth, page(Int, UUID) }

    var body: some View {
        if let document = MediaDecoder.pdf(data) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    Text("Page").foregroundStyle(.secondary)
                    TextField("", value: Binding(get: { page }, set: { command = .page($0, UUID()) }), format: .number)
                        .frame(width: 40).multilineTextAlignment(.center).accessibilityLabel("Page")
                    Text("of \(pages)").foregroundStyle(.secondary)
                    Button { command = .zoomOut } label: { Image(systemName: "minus") }.help("Zoom out").accessibilityLabel("Zoom out")
                    Button { command = .zoomIn } label: { Image(systemName: "plus") }.help("Zoom in").accessibilityLabel("Zoom in")
                    Button("Fit width") { command = .fitWidth }
                }
                .font(.system(size: 11)).controlSize(.small)
                .padding(.horizontal, 12).frame(height: 30)
                Divider()
                PDFKitView(document: document, command: $command, page: $page)
                    .onAppear { pages = document.pageCount }
            }
        } else {
            CantShowView(title: "Can't show this PDF", detail: MediaDecoder.failure)
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var command: PDFViewerView.PDFCommand?
    @Binding var page: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.maxScaleFactor = 2
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        context.coordinator.observe(view) { number in DispatchQueue.main.async { page = number } }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let command else { return }
        switch command {
        case .zoomIn: view.autoScales = false; view.scaleFactor = min(2, view.scaleFactor * 1.25)
        case .zoomOut: view.autoScales = false; view.scaleFactor = max(0.1, view.scaleFactor / 1.25)
        case .fitWidth: view.autoScales = true
        case let .page(number, _):
            if let target = document.page(at: max(0, min(document.pageCount - 1, number - 1))) { view.go(to: target) }
        }
        DispatchQueue.main.async { self.command = nil }
    }

    final class Coordinator {
        private var token: NSObjectProtocol?
        func observe(_ view: PDFView, _ changed: @escaping (Int) -> Void) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view] _ in
                guard let view, let current = view.currentPage, let document = view.document else { return }
                changed(document.index(for: current) + 1)
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

// MARK: - Can't show (frame 18)

struct CantShowView: View {
    let title: String
    let detail: String
    var path: String? = nil
    var canReveal = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 34)).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if let path {
                HStack(spacing: 8) {
                    Button("Copy Path") { FileOutlineView.Coordinator.copy(path) }
                    if canReveal { Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Markdown preview (frame 06)

/// The rendered preview of a Markdown tab's current text. Hardened: no
/// JavaScript, a strict Content-Security-Policy, no cookies or storage, no
/// referrer, and it never navigates: links open outside (http, mailto), in
/// uHerdr (files in the space), or not at all.
struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    let name: String
    /// The document's and the space folder's absolute paths on the device.
    let documentPath: String
    let root: String
    /// Reads an image of the space for the page (50 MB cap, inside the space only).
    let readAsset: @Sendable (String) async throws -> FileReader.Raw
    var fragment: String? = nil
    var onOpenFile: (String, String?) -> Void

    static let scheme = "uherdr-asset"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator.assets, forURLScheme: Self.scheme)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsLinkPreview = false
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.assets.root = root
        coordinator.assets.read = readAsset
        let page = MarkdownRenderer.page(markdown, title: name) { href in
            if case let .disabled(reason) = MarkdownLink.resolve(href, document: documentPath, root: root) { return reason }
            return nil
        }
        guard page != coordinator.shownPage else {
            coordinator.scroll(view, to: fragment)
            return
        }
        coordinator.shownPage = page
        coordinator.pendingFragment = fragment
        view.loadHTMLString(page, baseURL: Self.baseURL(document: documentPath, root: root))
    }

    /// The document's own URL under the asset scheme, relative to the space
    /// folder, so relative links and images resolve inside the space ("/x"
    /// means the space folder, as on GitHub) and "#heading" stays in the page.
    static func baseURL(document: String, root: String) -> URL {
        let top = root.hasSuffix("/") ? root : root + "/"
        let relative = document.hasPrefix(top) ? String(document.dropFirst(top.count)) : (document as NSString).lastPathComponent
        var components = URLComponents()
        components.scheme = scheme
        components.host = "space"
        components.path = "/" + relative
        return components.url ?? URL(string: "\(scheme)://space/")!
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MarkdownPreviewView?
        let assets = AssetHandler()
        var shownPage = ""
        var pendingFragment: String?
        private var scrolledTo: String?

        func scroll(_ view: WKWebView, to fragment: String?) {
            guard let fragment, fragment != scrolledTo else { return }
            scrolledTo = fragment
            // The app's own call works with content JavaScript off.
            let id = fragment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            view.evaluateJavaScript("document.getElementById('\(id)')?.scrollIntoView()")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let fragment = pendingFragment
            pendingFragment = nil
            scrolledTo = nil
            scroll(webView, to: fragment)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let parent, let url = action.request.url else { return decisionHandler(.cancel) }
            // The page's own load (and its subresources) is allowed; nothing else navigates it.
            if action.navigationType == .other, action.targetFrame?.isMainFrame == true,
               url.absoluteString.hasPrefix(MarkdownPreviewView.baseURL(document: parent.documentPath, root: parent.root).absoluteString) {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            guard action.navigationType == .linkActivated else { return }
            if url.scheme == MarkdownPreviewView.scheme {
                let top = parent.root.hasSuffix("/") ? String(parent.root.dropLast()) : parent.root
                let path = MarkdownLink.normalize(top + "/" + (url.path.removingPercentEncoding ?? url.path))
                if path == MarkdownLink.normalize(parent.documentPath) {
                    if let fragment = url.fragment { scrolledTo = nil; scroll(webView, to: fragment.removingPercentEncoding ?? fragment) }
                } else {
                    parent.onOpenFile(path, url.fragment?.removingPercentEncoding)
                }
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Serves `uherdr-asset://space/<path in the space>` from the space's
    /// folder, through the same reads (and boundary checks) as editor tabs.
    final class AssetHandler: NSObject, WKURLSchemeHandler {
        var root = "/"
        var read: (@Sendable (String) async throws -> FileReader.Raw)?
        private var running: [ObjectIdentifier: Task<Void, Never>] = [:]

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url, let read else {
                task.didFailWithError(URLError(.badURL)); return
            }
            let top = root.hasSuffix("/") ? String(root.dropLast()) : root
            let path = MarkdownLink.normalize(top + "/" + (url.path.removingPercentEncoding ?? url.path))
            let key = ObjectIdentifier(task)
            running[key] = Task { @MainActor [weak self] in
                let result: FileReader.Raw?
                do { result = try await read(path) } catch { result = nil }
                guard let self, self.running.removeValue(forKey: key) != nil else { return } // stopped meanwhile
                guard case let .data(data)? = result else {
                    task.didFailWithError(URLError(.fileDoesNotExist)); return
                }
                guard MediaDecoder.image(data) != nil else {
                    task.didFailWithError(URLError(.cannotDecodeContentData)); return
                }
                task.didReceive(URLResponse(url: url, mimeType: Self.mimeType(path), expectedContentLength: data.count, textEncodingName: nil))
                task.didReceive(data)
                task.didFinish()
            }
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
            running.removeValue(forKey: ObjectIdentifier(task))?.cancel()
        }

        static func mimeType(_ path: String) -> String {
            switch (path as NSString).pathExtension.lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "svg": return "image/svg+xml"
            case "heic", "heif": return "image/heic"
            case "bmp": return "image/bmp"
            case "ico": return "image/x-icon"
            default: return "application/octet-stream"
            }
        }
    }
}
