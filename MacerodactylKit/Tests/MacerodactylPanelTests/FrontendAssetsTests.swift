import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

@testable import MacerodactylPanel

@Suite struct FrontendAssetsTests {
    let base = PanelServerTests()

    /// The load-bearing XSS invariant of the extracted frontend: the SPA builds
    /// DOM with safe APIs and NEVER assigns parsed HTML. If this fails, someone
    /// reintroduced an innerHTML/outerHTML/insertAdjacentHTML sink and a missed
    /// escape could become a stored XSS again.
    @Test func panelJSHasNoHTMLInjectionSinks() {
        let js = PanelAssets.string(.panelJS)
        #expect(!js.isEmpty)
        for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"] {
            #expect(!js.contains(sink), "panel.js must not use \(sink) — build DOM with h()/textContent instead")
        }
        // The safe builder and its text sink must be present.
        #expect(js.contains("textContent"))
    }

    @Test func loginJSHasNoHTMLInjectionSinks() {
        let js = PanelAssets.string(.loginJS)
        #expect(!js.isEmpty)
        for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"] {
            #expect(!js.contains(sink))
        }
    }

    @Test func adminJSHasNoHTMLInjectionSinks() {
        let js = PanelAssets.string(.adminJS)
        #expect(!js.isEmpty)
        for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"] {
            #expect(!js.contains(sink), "admin.js must not use \(sink) — build DOM with h()/textContent instead")
        }
        #expect(js.contains("textContent"))
    }

    @Test func allAssetsLoadAndAreNonEmpty() {
        for asset in PanelAssets.Asset.allCases {
            #expect(!PanelAssets.string(asset).isEmpty, "\(asset.rawValue) should load from the bundle")
        }
    }

    @Test func assetsAreServedWithCorrectContentType() async throws {
        let harness = try await base.makeHarness()
        try await harness.app.test(.router) { client in
            try await client.execute(uri: "/assets/panel.js", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("javascript") == true)
                #expect(!String(buffer: response.body).isEmpty)
            }
            try await client.execute(uri: "/assets/panel.css", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("text/css") == true)
            }
        }
    }

    @Test func loginPageServedAndAppPageRequiresAuth() async throws {
        let harness = try await base.makeHarness()
        try await harness.app.test(.router) { client in
            // Login page is public HTML and references the extracted assets.
            try await client.execute(uri: "/login", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("/assets/login.js"))
                #expect(body.contains("/assets/login.css"))
            }
            // The app page redirects to /login when unauthenticated (no leak).
            try await client.execute(uri: "/me", method: .get) { response in
                #expect(response.status == .seeOther)
                #expect(response.headers[.location] == "/login")
            }
        }
    }
}
