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

    /// The served-page flows a browser actually drives (not the JSON API the
    /// route tests hit): the setup and reset pages must POST to the right
    /// endpoint AND carry the custom CSRF header — a served page that hit the
    /// wrong endpoint or dropped the header is exactly the kind of gap that the
    /// API-only tests can't see (the class of the earlier 2FA served-page bug).
    @Test func setupAndResetJSPostToTheirEndpointsWithCSRF() {
        let csrf = PanelHeaders.csrf.canonicalName  // "x-macerodactyl-csrf"
        let setup = PanelAssets.string(.setupJS)
        #expect(setup.contains("'/setup'") || setup.contains("\"/setup\""))
        #expect(setup.lowercased().contains(csrf), "setup.js must send the CSRF header")
        #expect(setup.contains("location.href"), "setup.js signs the new admin in")
        for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"] {
            #expect(!setup.contains(sink))
        }

        let reset = PanelAssets.string(.resetJS)
        #expect(reset.contains("'/reset'") || reset.contains("\"/reset\""))
        #expect(reset.lowercased().contains(csrf), "reset.js must send the CSRF header")
        #expect(reset.contains("URLSearchParams") || reset.contains("token"), "reset.js reads the token from the link")
        for sink in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"] {
            #expect(!reset.contains(sink))
        }
    }

    /// The served login page — where the 2FA flow lives — must drive the second
    /// factor from the page itself (send CSRF, react to `totpRequired`), since
    /// that page interaction is precisely what an API-only test never exercises.
    @Test func loginJSDrivesTheTwoFactorFlow() {
        let js = PanelAssets.string(.loginJS)
        #expect(js.lowercased().contains(PanelHeaders.csrf.canonicalName), "login.js must send the CSRF header")
        #expect(js.contains("totpRequired"), "login.js must handle the 2FA challenge the server returns")
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
