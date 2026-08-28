import AppKit
import WebKit

enum SessionError: LocalizedError {
    case pageLoadFailed(String)
    case bridgeFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .pageLoadFailed(let m): return "Console page failed to load: \(m)"
        case .bridgeFailed(let m): return "Console request failed: \(m)"
        case .malformedResponse: return "Console returned an unexpected response."
        }
    }
}

/// Keeps an off-screen console page alive and runs the token-plan queries inside
/// its own JavaScript context, so cookies, referer and same-origin rules all hold
/// without copying a cookie jar around.
@MainActor
final class QwenSession: NSObject, WKNavigationDelegate {
    /// Where the user signs in, and what "Open Console" opens.
    static let consoleURL = URL(string: "https://home.qwencloud.com/analytics/token-plan/individual")!

    /// The page the poller actually keeps loaded. It is same-origin with the
    /// console but is a bare JSON document, so none of the console SPA's
    /// trackers and polling scripts stay running between refreshes.
    static let hostURL = URL(string: "https://home.qwencloud.com/tool/user/info.json")!

    private let webView: WKWebView
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var isLoading = false
    private var hasLoaded = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persists cookies across launches
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// Loads the console page if it is not up yet. Safe to call repeatedly.
    func ensureLoaded() async throws {
        if hasLoaded { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadWaiters.append(cont)
            if !isLoading {
                isLoading = true
                webView.load(URLRequest(url: Self.hostURL))
            }
        }
    }

    /// Drops the cached page so the next refresh reloads from scratch.
    func invalidate() {
        hasLoaded = false
    }

    /// Runs one full read: session token, then usage + subscription in parallel.
    func fetchSnapshot() async throws -> BridgeResult {
        try await ensureLoaded()
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(Self.bridgeScript,
                                                        arguments: [:],
                                                        in: nil,
                                                        contentWorld: .page)
        } catch {
            hasLoaded = false          // page may have navigated away or died
            throw SessionError.bridgeFailed(error.localizedDescription)
        }
        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw SessionError.malformedResponse
        }
        do {
            return try JSONDecoder().decode(BridgeResult.self, from: data)
        } catch {
            throw SessionError.malformedResponse
        }
    }

    /// Clears every cookie in the shared store, which logs the console out.
    func logOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let qwen = records.filter { $0.displayName.contains("qwencloud") || $0.displayName.contains("aliyun") || $0.displayName.contains("alibaba") }
        await store.removeData(ofTypes: types, for: qwen)
        hasLoaded = false
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasLoaded = true
        isLoading = false
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failLoad(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failLoad(error)
    }

    /// The web content process can be killed independently of the app. Drop the
    /// cached page so the next refresh reloads instead of talking to a corpse.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hasLoaded = false
        isLoading = false
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: SessionError.pageLoadFailed("web content process terminated")) }
    }

    private func failLoad(_ error: Error) {
        isLoading = false
        hasLoaded = false
        let waiters = loadWaiters
        loadWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: SessionError.pageLoadFailed(error.localizedDescription)) }
    }

    // MARK: - Bridge

    /// Runs in the console page: reads `secToken`, then calls the one-console
    /// gateway twice. Returns a JSON string so decoding stays on the Swift side.
    private static let bridgeScript = """
    try {
      const infoRes = await fetch('/tool/user/info.json', { credentials: 'include' });
      const info = await infoRes.json();
      const token = info && info.data && info.data.secToken;
      if (!token) { return JSON.stringify({ loggedIn: false }); }

      const cornerstoneParam = {
        domain: 'home.qwencloud.com',
        consoleSite: 'QWENCLOUD',
        console: 'ONE_CONSOLE',
        xsp_lang: 'en-US',
        protocol: 'V2',
        productCode: 'p_efm'
      };

      async function gateway(api, extra) {
        const params = {
          Api: api,
          V: '1.0',
          Data: Object.assign({}, extra || {}, { cornerstoneParam: cornerstoneParam })
        };
        const body = new URLSearchParams();
        body.set('product', 'sfm_bailian');
        body.set('action', 'IntlBroadScopeAspnGateway');
        body.set('region', 'ap-southeast-1');
        body.set('sec_token', token);
        body.set('params', JSON.stringify(params));
        const res = await fetch(
          'https://cs-data.qwencloud.com/data/api.json?product=sfm_bailian&action=IntlBroadScopeAspnGateway',
          {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body.toString()
          }
        );
        const json = await res.json();
        const outer = json && json.data;
        if (outer && outer.success === false) {
          throw new Error(outer.errorCode || outer.errorMsg || 'gateway error');
        }
        return (outer && outer.DataV2 && outer.DataV2.data && outer.DataV2.data.data) || null;
      }

      const [usage, subscription] = await Promise.all([
        gateway('zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage', {}),
        gateway('zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription',
                { commodityCode: 'sfm_tokenplansolo_public_intl' })
      ]);

      return JSON.stringify({ loggedIn: true, usage: usage, subscription: subscription });
    } catch (e) {
      return JSON.stringify({ loggedIn: true, error: String((e && e.message) || e) });
    }
    """
}
