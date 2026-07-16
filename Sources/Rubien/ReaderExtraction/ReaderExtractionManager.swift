#if os(macOS)
import Foundation
import OSLog
import WebKit
import RubienCore

private let readerExtractionLog = Logger(subsystem: "Rubien", category: "OnlineReadable")

/// 在线阅读：原文页注入 Defuddle / Readability；`readerResult` 由本类接收，`deinit` 移除 handler。
final class ReaderExtractionManager: NSObject, WKScriptMessageHandler {
    static let readerResultHandlerName = "readerResult"

    /// 与 Safari 接近，减轻部分站点对 WKWebView 默认 UA 的拦截。
    static let safariLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    weak var hostWebView: WKWebView?

    /// 仍为「在线阅读」且处于 busy（未最终失败）时返回 true。
    var isExtractionBusyContext: (() -> Bool)?

    var onDefuddleSuccess: ((String?, String, String?, String?) -> Void)?
    var onReadabilitySuccess: ((String?, String, String?, String?) -> Void)?
    var onTerminalFailure: ((String) -> Void)?

    private var hasRetriedAfterDelay = false
    private var defuddleResultHandled = false

    /// Best-guess cover image URL captured from the live DOM before Defuddle prunes
    /// the page. Used in `augmentContentWithCoverImageIfMissing` to inject a hero
    /// image back into the extracted content when Defuddle's blocklist (which
    /// strips `header`, `[class*="cover-"]`, etc.) has removed the original.
    var capturedCoverImageURL: String?

    private static var readabilityScriptCache: String?

    func resetForNewNavigation() {
        hasRetriedAfterDelay = false
        defuddleResultHandled = false
        capturedCoverImageURL = nil
    }

    private func resetDefuddleOnly() {
        defuddleResultHandled = false
    }

    deinit {
        let name = Self.readerResultHandlerName
        let ucc = hostWebView?.configuration.userContentController
        DispatchQueue.main.async {
            ucc?.removeScriptMessageHandler(forName: name)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.readerResultHandlerName,
              let body = message.body as? [String: Any],
              let source = body["source"] as? String,
              source == "defuddle"
        else { return }

        defuddleResultHandled = true
        let ok = (body["ok"] as? Bool) == true
        guard ok,
              let content = body["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            readerExtractionLog.notice("readerResult defuddle ok=false → Readability")
            DispatchQueue.main.async { [weak self] in
                guard let self, let wv = self.hostWebView else { return }
                self.runReadabilityForOnlineRead(in: wv)
            }
            return
        }

        let title = body["title"] as? String
        let excerpt = (body["description"] as? String) ?? (body["excerpt"] as? String)
        let byline = body["author"] as? String
        let augmented = Self.augmentContentWithCoverImageIfMissing(content, coverImageURL: capturedCoverImageURL)
        readerExtractionLog.notice("readerResult Defuddle succeeded contentLength=\(content)")
        DispatchQueue.main.async { [weak self] in
            self?.onDefuddleSuccess?(title, augmented, excerpt, byline)
        }
    }

    // MARK: - Pipeline

    func runOnlineArticleExtraction(from webView: WKWebView) {
        hostWebView = webView

        // Fully client-rendered pages (React/Vue/Next/Notion/… SPAs) leave their
        // mount node EMPTY at `didFinish` and only fill it 1–4s later once the
        // framework hydrates. Extracting immediately would run Defuddle /
        // Readability against an empty DOM and fail. Wait for substantive
        // content to appear (bounded), THEN capture the cover image + run
        // Defuddle. Static pages clear the first probe instantly, so they pay
        // ~no latency. This generalizes — and replaces — the former Notion-only
        // fixed 5s delay (the "substantive-content guard" the old TODO promised).
        waitForSubstantiveContent(in: webView) { [weak self, weak webView] in
            guard let self, let webView else { return }
            // Capture a cover-image candidate from the LIVE DOM before Defuddle strips
            // headers/cover containers. Best-effort: if the capture script fails or
            // returns nothing, augmentation just no-ops. Adds one extra
            // evaluateJavaScript round-trip (single-digit ms in practice).
            webView.evaluateJavaScript(Self.coverImageCaptureJS) { [weak self] result, _ in
                guard let self else { return }
                let captured = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.capturedCoverImageURL = (captured?.isEmpty ?? true) ? nil : captured
                self.injectAndRunDefuddle(in: webView)
            }
        }
    }

    /// Polls the live DOM until it exposes substantive article content, then
    /// invokes `proceed`. Exits the instant content appears (a static page
    /// clears the very first probe), and proceeds anyway once `maxWait` elapses
    /// so a genuinely empty / login-walled page still reaches the existing
    /// Defuddle → Readability → failure path. Notion keeps a 5s floor so a clip
    /// never captures its pre-hydration marketing shell — the guarantee the old
    /// fixed delay provided. Polling (vs. one async wait) keeps this consistent
    /// with the rest of the manager's `evaluateJavaScript` callback style.
    private func waitForSubstantiveContent(in webView: WKWebView, then proceed: @escaping () -> Void) {
        let host = (webView.url?.host ?? "").lowercased()
        let isNotion = host == "notion.site" || host.hasSuffix(".notion.site") ||
                       host == "notion.so" || host.hasSuffix(".notion.so")
        let minWaitMs: Double = isNotion ? 5_000 : 0
        let maxWaitMs: Double = isNotion ? 12_000 : 10_000
        let intervalMs = 300
        let startedAt = DispatchTime.now()

        func poll() {
            // Stop polling if online-read was canceled mid-wait (tab switch /
            // new navigation) or the host WKWebView went away — we must not
            // keep polling, then Defuddle, a context that no longer wants the
            // result. Re-fetch via the weak `hostWebView` so a torn-down reader
            // releases promptly. `nil` busy-context = no opinion = proceed.
            guard isExtractionBusyContext?() != false, let webView = hostWebView else { return }
            webView.evaluateJavaScript(Self.contentReadinessProbeJS) { [weak self] result, _ in
                // Re-check after the round-trip: the user may have canceled
                // while the probe was in flight.
                guard let self, self.isExtractionBusyContext?() != false else { return }
                let score = (result as? NSNumber)?.intValue ?? 0
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- startedAt.uptimeNanoseconds) / 1_000_000  // ms since gate start
                let ready = score >= Self.contentReadinessScoreThreshold && elapsed >= minWaitMs
                if ready || elapsed >= maxWaitMs {
                    if elapsed >= maxWaitMs && !ready {
                        readerExtractionLog.notice("Content-readiness gate timed out (\(Int(elapsed))ms, score=\(score)) — extracting best-effort")
                    }
                    proceed()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(intervalMs)) { poll() }
            }
        }
        poll()
    }

    private func injectAndRunDefuddle(in webView: WKWebView) {
        readerExtractionLog.notice("ReaderExtractionManager: injecting ClipperDefuddle.js and invoking RubienDefuddleExtract()")
        guard let defuddleSrc = Self.loadClipperDefuddleScript() else {
            readerExtractionLog.error("ClipperDefuddle.js resource not found → falling back to Readability")
            runReadabilityForOnlineRead(in: webView)
            return
        }

        webView.evaluateJavaScript(defuddleSrc) { [weak self] _, error in
            guard let self else { return }
            if let error {
                readerExtractionLog.error("Failed to inject ClipperDefuddle.js: \(error.localizedDescription) → falling back to Readability")
                self.runReadabilityForOnlineRead(in: webView)
                return
            }
            readerExtractionLog.notice("ClipperDefuddle.js loaded, invoking RubienDefuddleExtract()")
            self.defuddleResultHandled = false
            webView.evaluateJavaScript("RubienDefuddleExtract()") { [weak self] result, err2 in
                guard let self else { return }
                if let err2 {
                    readerExtractionLog.error("RubienDefuddleExtract threw: \(err2.localizedDescription) → falling back to Readability")
                    self.runReadabilityForOnlineRead(in: webView)
                    return
                }
                // Safety-net timeout: if postMessage hasn't delivered the
                // result by this point, parse the JS return value (sync
                // fallback) or fall back to Readability. Sized to cover the
                // worst-case async pipeline: toggle pre-expansion (~5s on
                // pathologically nested Notion pages) + Defuddle parseAsync
                // (~1-2s for math-heavy pages with temml MathML conversion).
                // Was 0.2s historically; that was tight when the only async
                // work was Defuddle parseAsync, and broke after adding the
                // Notion pre-expansion lifecycle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
                    guard let self else { return }
                    if self.defuddleResultHandled { return }
                    self.processDefuddleJSONFallback(result as? String, webView: webView)
                }
            }
        }
    }

    private func processDefuddleJSONFallback(_ jsonStr: String?, webView: WKWebView) {
        guard let jsonStr,
              let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["ok"] as? Bool) == true,
              let content = obj["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            let parsed = jsonStr.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let err = parsed?["error"] as? String
            readerExtractionLog.notice("Defuddle completion fallback parse failed ok=\(parsed?["ok"] as? Bool ?? false) err=\(err ?? "nil") → falling back to Readability")
            runReadabilityForOnlineRead(in: webView)
            return
        }
        let title = obj["title"] as? String
        let excerpt = (obj["description"] as? String) ?? (obj["excerpt"] as? String)
        let byline = obj["author"] as? String
        let augmented = Self.augmentContentWithCoverImageIfMissing(content, coverImageURL: capturedCoverImageURL)
        readerExtractionLog.notice("Defuddle completion fallback succeeded contentLength=\(content.count)")
        onDefuddleSuccess?(title, augmented, excerpt, byline)
    }

    func runReadabilityForOnlineRead(in webView: WKWebView) {
        readerExtractionLog.notice("runReadabilityForOnlineRead")
        guard let scriptSource = Self.loadReadabilityScript() else {
            onTerminalFailure?(String(localized: "Missing Readability.js resource.", bundle: .module))
            return
        }
        let js = scriptSource + "\n" + Self.readabilityBootstrapJS
        runReadabilityExtractionCore(in: webView, script: js)
    }

    private func runReadabilityExtractionCore(in webView: WKWebView, script js: String) {
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            if let error {
                self.failOrRetry(webView: webView, message: "Extraction script error: \(error.localizedDescription)")
                return
            }
            guard let jsonStr = result as? String,
                  let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                self.failOrRetry(webView: webView, message: "Online reading failed: could not parse extraction result.")
                return
            }

            let ok = (obj["ok"] as? Bool) == true
            guard ok, let content = obj["content"] as? String else {
                let err = (obj["err"] as? String) ?? "parse_failed"
                self.failOrRetry(webView: webView, message: "Could not extract article from page (\(err)). Try Clipped, or check if the page requires login.")
                return
            }

            let title = obj["title"] as? String
            let excerpt = obj["excerpt"] as? String
            let byline = obj["byline"] as? String
            let augmented = Self.augmentContentWithCoverImageIfMissing(content, coverImageURL: self.capturedCoverImageURL)
            readerExtractionLog.notice("Readability succeeded contentLength=\(content.count)")
            self.onReadabilitySuccess?(title, augmented, excerpt, byline)
        }
    }

    private func failOrRetry(webView: WKWebView, message: String) {
        Task { @MainActor in
            guard self.isExtractionBusyContext?() == true else { return }
            if !self.hasRetriedAfterDelay {
                self.hasRetriedAfterDelay = true
                readerExtractionLog.notice("Full extraction chain failed, retrying once after 1.5s: \(message)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard self.isExtractionBusyContext?() == true else { return }
                self.resetDefuddleOnly()
                self.runOnlineArticleExtraction(from: webView)
                return
            }
            self.onTerminalFailure?(message)
        }
    }

    // MARK: - Scripts

    private static func loadClipperDefuddleScript() -> String? {
        // Re-read the bundle on every clip — npm-rebuild iterations
        // need to land immediately. Cost is ~5ms per clip on a 700KB
        // bundle, which is in the noise compared to extraction time.
        guard let url = Bundle.module.url(forResource: "ClipperDefuddle", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return s
    }

    private static func loadReadabilityScript() -> String? {
        // Cached for the process lifetime — Readability.js is vendored
        // upstream and not iterated on during development.
        if let cached = Self.readabilityScriptCache { return cached }
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        Self.readabilityScriptCache = s
        return s
    }

    private static let readabilityBootstrapJS = """
    (function() {
      try {
        var clone = document.cloneNode(true);
        if (!clone || !clone.documentElement) {
          return JSON.stringify({ ok: false, err: 'no_document' });
        }
        var reader = new Readability(clone);
        var art = reader.parse();
        if (!art || !art.content) {
          return JSON.stringify({ ok: false, err: 'parse_failed' });
        }
        return JSON.stringify({
          ok: true,
          title: art.title || '',
          content: art.content,
          excerpt: art.excerpt || '',
          byline: art.byline || ''
        });
      } catch (e) {
        return JSON.stringify({ ok: false, err: String(e) });
      }
    })();
    """


    // MARK: - Content-readiness gate

    /// Minimum readiness score for the live DOM to count as "has an article".
    /// An un-hydrated SPA shell scores ~0; a couple of sentences or a few
    /// structural blocks clear this bar. Deliberately low — its only job is to
    /// separate "nothing rendered yet" from "real content present".
    static let contentReadinessScoreThreshold = 250

    /// Scores how much substantive article content the live DOM holds right now:
    /// `textContent` length (layout-independent — works in hidden / zero-size
    /// webviews, unlike `innerText`) plus a weighted count of structural block
    /// elements, measured inside the best content container (semantic
    /// article/main first, then the common SPA mount nodes, then `<body>`).
    /// Returns ~0 while a client-rendered page is still an empty shell.
    static let contentReadinessProbeJS = #"""
    (function () {
      function score(el) {
        if (!el) return 0;
        var textLen = (el.textContent || '').trim().length;
        var blocks = el.querySelectorAll('p, li, h1, h2, h3, h4, pre, blockquote, figure, table, img').length;
        return textLen + blocks * 50;
      }
      var el = document.querySelector('article') ||
               document.querySelector('main') ||
               document.querySelector('[role="main"]') ||
               document.getElementById('root') ||
               document.getElementById('app') ||
               document.getElementById('__next') ||
               document.body;
      return score(el);
    })()
    """#

    // MARK: - Cover-image capture & injection (Fix 4)

    /// Returns the best-guess cover image URL from the live DOM as an absolute string,
    /// or empty string if none found. Priority: og:image / twitter:image unless its
    /// filename identifies a brand asset, then a size-gated scan of header / cover /
    /// hero <img> elements. The same brand-asset guard applies to both paths.
    static let coverImageCaptureJS = #"""
    (function() {
      function abs(u) { try { return new URL(u, document.URL).toString(); } catch(_) { return u || ''; } }
      function looksLikeBrandAsset(u) {
        var pathname = '';
        try { pathname = new URL(u, document.URL).pathname || ''; } catch(_) { pathname = String(u || '').split(/[?#]/)[0]; }
        var filename = pathname.substring(pathname.lastIndexOf('/') + 1);
        return /(?:^|[-_.])(logo|icon|favicon|avatar|brandmark|wordmark)(?=[-_.@\d]|$)/i.test(filename);
      }
      function pickFromSrcset(srcset) {
        if (!srcset) return '';
        var parts = srcset.split(',').map(function(s) { return s.trim(); });
        var best = '', bestW = 0;
        for (var i = 0; i < parts.length; i++) {
          var m = parts[i].match(/^(\S+)\s+(\d+(?:\.\d+)?)w$/);
          if (m && Number(m[2]) > bestW) { bestW = Number(m[2]); best = m[1]; }
        }
        if (best) return best;
        var first = parts[0] ? parts[0].split(/\s+/)[0] : '';
        return first || '';
      }
      function bigEnough(img) {
        var w = img.naturalWidth || (img.getBoundingClientRect && img.getBoundingClientRect().width) || 0;
        var h = img.naturalHeight || (img.getBoundingClientRect && img.getBoundingClientRect().height) || 0;
        return w >= 200 && h >= 150;
      }
      var og = document.querySelector('meta[property="og:image"], meta[name="og:image"], meta[name="twitter:image"]');
      if (og && og.content && !looksLikeBrandAsset(og.content)) return abs(og.content);
      var candidates = document.querySelectorAll('header img, [class*="cover" i] img, [id*="cover" i] img, figure.cover img, .post-header img, .article-header img, article > figure:first-of-type img');
      for (var j = 0; j < candidates.length; j++) {
        var img = candidates[j];
        if (!bigEnough(img)) continue;
        var url = img.currentSrc || img.src || pickFromSrcset(img.getAttribute('srcset')) || img.getAttribute('data-src') || '';
        if (url && !looksLikeBrandAsset(url)) return abs(url);
      }
      return '';
    })()
    """#

    /// Injects a `<figure class="rubien-cover-image">` at the top of the extracted body
    /// if `coverImageURL` is set AND the body doesn't already contain an equivalent
    /// image (compared by host + last-path-component to absorb CDN canonicalization).
    static func augmentContentWithCoverImageIfMissing(
        _ html: String,
        coverImageURL: String?
    ) -> String {
        guard let cover = coverImageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cover.isEmpty,
              !isLikelyBrandAssetURL(cover),
              let coverURL = URL(string: cover) else { return html }

        let coverKey = imageEquivalenceKey(for: coverURL)
        // Match <img> src/srcset/data-src/data-srcset whether the value is double-
        // quoted, single-quoted, or unquoted (HTML5 permits all three). The capture
        // groups (2 / 3 / 4) reflect the three branches; we pick whichever non-empty.
        let pattern = #"<img\b[^>]*?\b(?:src|srcset|data-src|data-srcset)\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))"#

        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let ns = html as NSString
            var matchFound = false
            regex.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
                guard let m = match, m.numberOfRanges >= 4 else { return }
                let attrValue: String = {
                    for idx in 1...3 {
                        let r = m.range(at: idx)
                        if r.location != NSNotFound { return ns.substring(with: r) }
                    }
                    return ""
                }()
                guard !attrValue.isEmpty else { return }
                // srcset values: "url 1x, url2 2x" or "url 300w, url2 600w". Take each leading URL.
                for entry in attrValue.split(separator: ",") {
                    let trimmedEntry = entry.trimmingCharacters(in: .whitespaces)
                    let firstToken = trimmedEntry.split(separator: " ").first.map(String.init) ?? ""
                    guard !firstToken.isEmpty,
                          let candidateURL = URL(string: firstToken, relativeTo: coverURL)?.absoluteURL else { continue }
                    if imageEquivalenceKey(for: candidateURL) == coverKey {
                        matchFound = true
                        stop.pointee = true
                        return
                    }
                }
            }
            if matchFound { return html }
        } else if html.contains(cover) {
            return html
        }

        let escaped = cover
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return "<figure class=\"rubien-cover-image\"><img src=\"\(escaped)\" alt=\"\"></figure>\n" + html
    }

    /// Removes a legacy, Rubien-injected cover only when its URL identifies a
    /// brand asset. Ordinary article images and legitimate injected covers are
    /// left untouched. This lets older persisted clips benefit from improved
    /// cover selection without mutating their stored snapshot.
    nonisolated static func removingInjectedBrandCoverIfNeeded(from html: String) -> String {
        let pattern = #"^\s*<figure\s+class="rubien-cover-image"\s*>\s*<img\s+src="([^"]+)"\s+alt=""\s*/?\s*>\s*</figure>\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: html, options: [], range: fullRange),
              match.numberOfRanges >= 2,
              match.range(at: 1).location != NSNotFound,
              isLikelyBrandAssetURL(ns.substring(with: match.range(at: 1))) else {
            return html
        }
        return ns.replacingCharacters(in: match.range(at: 0), with: "")
    }

    nonisolated private static func isLikelyBrandAssetURL(_ rawValue: String) -> Bool {
        let unescaped = rawValue.replacingOccurrences(of: "&amp;", with: "&")
        let decoded = unescaped.removingPercentEncoding ?? unescaped
        let filename: String
        if let url = URL(string: decoded), !url.lastPathComponent.isEmpty {
            filename = url.lastPathComponent
        } else {
            let path = decoded.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? decoded
            filename = (path as NSString).lastPathComponent
        }
        let pattern = #"(?:^|[-_.])(logo|icon|favicon|avatar|brandmark|wordmark)(?=[-_.@\d]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        let nsFilename = filename as NSString
        return regex.firstMatch(
            in: filename,
            options: [],
            range: NSRange(location: 0, length: nsFilename.length)
        ) != nil
    }

    private static func imageEquivalenceKey(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let lastPath = url.lastPathComponent.lowercased()
        return "\(host)|\(lastPath)"
    }
}
#endif
