import Foundation

/// The web panel's frontend is a set of static files in the bundle
/// (`Resources/panel/`), NOT a hand-built HTML string. It is rendered entirely
/// client-side with safe DOM APIs (see `panel.js`), so untrusted values can only
/// become text nodes or attribute values — a missed escape can't be a latent
/// XSS. This type just loads those files from the bundle and hands them to the
/// routes; there is no string interpolation of data anywhere in the serving
/// path.
enum PanelAssets {
    /// Known assets, mapped to (resource filename, MIME type). Serving is by this
    /// fixed allow-list only — never a filename taken from the request URL, so
    /// there is no path traversal into the bundle.
    enum Asset: String, CaseIterable {
        case appHTML = "app.html"
        case loginHTML = "login.html"
        case panelCSS = "panel.css"
        case loginCSS = "login.css"
        case panelJS = "panel.js"
        case loginJS = "login.js"

        var contentType: String {
            switch self {
            case .appHTML, .loginHTML: "text/html; charset=utf-8"
            case .panelCSS, .loginCSS: "text/css; charset=utf-8"
            case .panelJS, .loginJS: "application/javascript; charset=utf-8"
            }
        }
    }

    /// Loaded once and cached — the files never change at runtime.
    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [Asset: String] = [:]
        func value(for asset: Asset) -> String {
            lock.lock()
            defer { lock.unlock() }
            if let hit = store[asset] { return hit }
            let loaded = Self.load(asset)
            store[asset] = loaded
            return loaded
        }
        private static func load(_ asset: Asset) -> String {
            guard let url = Bundle.module.url(forResource: asset.rawValue, withExtension: nil, subdirectory: "panel"),
                let text = try? String(contentsOf: url, encoding: .utf8)
            else { return "" }
            return text
        }
    }

    static func string(_ asset: Asset) -> String { cache.value(for: asset) }
}
