import Foundation

/// Wraps converted markdown in a self-contained HTML page.
///
/// The page is locked down: a strict CSP with a per-load nonce means the only script
/// that can run is the bundled mermaid bootstrap, nothing can be fetched over the
/// network, and images only load from the `data:` URIs the converter inlined.
enum HTMLPage {

    static func wrap(body: String, title: String, isDark: Bool,
                     mermaidScript: String?, diagramCount: Int) -> String {
        let nonce = UUID().uuidString
        let needsDiagrams = diagramCount > 0
        let mermaid = needsDiagrams ? (mermaidScript ?? "") : ""
        let scriptSource = mermaid.isEmpty ? "'nonce-\(nonce)'" : "'nonce-\(nonce)' 'unsafe-eval'"

        var head = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; \
        img-src data: blob:; style-src 'unsafe-inline'; font-src data:; \
        script-src \(scriptSource); connect-src 'none'; form-action 'none'; base-uri 'none'">
        <title>\(MarkdownConverter.escapeHTML(title))</title>
        <style>\(stylesheet)</style>
        """

        if needsDiagrams, !mermaid.isEmpty {
            head += "\n<script nonce=\"\(nonce)\">\(mermaid)</script>"
        }

        var scripts = "<script nonce=\"\(nonce)\">\(findScript)</script>"
        if needsDiagrams {
            scripts += mermaid.isEmpty
                ? "<script nonce=\"\(nonce)\">\(missingMermaidScript)</script>"
                : "<script nonce=\"\(nonce)\">\(diagramScript(isDark: isDark))</script>"
        }

        return """
        <!DOCTYPE html>
        <html lang="en" data-theme="\(isDark ? "dark" : "light")">
        <head>
        \(head)
        </head>
        <body>
        <article id="content">
        \(body)
        </article>
        \(scripts)
        </body>
        </html>
        """
    }

    // MARK: - Stylesheet

    private static let stylesheet = """
    :root {
      --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --border: #d1d9e0;
      --code-bg: #f6f8fa; --quote-border: #d1d9e0; --link: #0969da;
      --table-stripe: #f6f8fa; --mark: #fff8c5; --mark-current: #ffb454;
      --tk-keyword: #cf222e; --tk-type: #953800; --tk-constant: #0550ae;
      --tk-string: #0a3069; --tk-number: #0550ae; --tk-comment: #6e7781;
      --tk-annotation: #8250df; --error-bg: #fff1e5; --error-fg: #9a3412;
    }
    html[data-theme="dark"] {
      --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --border: #3d444d;
      --code-bg: #161b22; --quote-border: #3d444d; --link: #4493f8;
      --table-stripe: #161b22; --mark: rgba(210,153,34,.45); --mark-current: #e3852b;
      --tk-keyword: #ff7b72; --tk-type: #ffa657; --tk-constant: #79c0ff;
      --tk-string: #a5d6ff; --tk-number: #79c0ff; --tk-comment: #8b949e;
      --tk-annotation: #d2a8ff; --error-bg: #3b2300; --error-fg: #ffb77c;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--fg);
      font: 14px/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    #content { max-width: 860px; margin: 0 auto; padding: 28px 32px 80px; }
    h1, h2, h3, h4, h5, h6 {
      line-height: 1.3; margin: 1.6em 0 .6em; font-weight: 600; scroll-margin-top: 16px;
    }
    h1 { font-size: 1.9em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.45em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.2em; } h4 { font-size: 1.05em; }
    h5 { font-size: 1em; } h6 { font-size: 1em; color: var(--muted); }
    #content > h1:first-child, #content > h2:first-child { margin-top: 0; }
    p, ul, ol, blockquote, table, pre { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { padding-left: 1.6em; }
    li { margin: .25em 0; }
    li > ul, li > ol { margin: .25em 0; }
    li.task { list-style: none; margin-left: -1.4em; }
    li.task input { margin-right: .5em; vertical-align: middle; }
    blockquote {
      padding: 0 1em; color: var(--muted); border-left: .25em solid var(--quote-border);
    }
    hr { height: 1px; border: 0; background: var(--border); margin: 1.8em 0; }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .88em;
      background: var(--code-bg); padding: .15em .35em; border-radius: 5px;
    }
    pre.code {
      background: var(--code-bg); border: 1px solid var(--border); border-radius: 8px;
      padding: 12px 14px; overflow-x: auto;
    }
    pre.code code {
      background: none; padding: 0; font-size: .85em; line-height: 1.5;
      display: block; white-space: pre;
    }
    table { border-collapse: collapse; display: block; overflow-x: auto; max-width: 100%; }
    th, td { border: 1px solid var(--border); padding: 6px 12px; text-align: left; }
    th { background: var(--table-stripe); font-weight: 600; }
    tbody tr:nth-child(2n) { background: var(--table-stripe); }
    img { max-width: 100%; border-radius: 6px; }
    .missing-image { color: var(--muted); font-size: .92em; }
    .missing-image .hint { font-size: .85em; opacity: .8; }
    .diagram {
      margin: 0 0 1.2em; padding: 14px; border: 1px solid var(--border);
      border-radius: 8px; background: var(--code-bg); overflow-x: auto;
    }
    .diagram-rendered svg { max-width: 100%; height: auto; display: block; margin: 0 auto; }
    .diagram-source { display: none; }
    .diagram.diagram-error { background: var(--error-bg); border-color: var(--error-fg); }
    .diagram.diagram-error .diagram-source {
      display: block; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: .82em; white-space: pre; overflow-x: auto; margin: 8px 0 0;
    }
    .diagram-message { color: var(--error-fg); font-size: .88em; font-weight: 600; }
    .tk-keyword { color: var(--tk-keyword); }
    .tk-type { color: var(--tk-type); }
    .tk-constant { color: var(--tk-constant); }
    .tk-string { color: var(--tk-string); }
    .tk-number { color: var(--tk-number); }
    .tk-comment { color: var(--tk-comment); }
    .tk-annotation { color: var(--tk-annotation); }
    mark.folio-match { background: var(--mark); color: inherit; border-radius: 2px; }
    mark.folio-match.current { background: var(--mark-current); }
    """

    // MARK: - Find

    /// ⌘F for the rendered view: wraps hits in <mark> and scrolls between them.
    /// Kept in the page because WebKit's own text finder cannot be driven from
    /// SwiftUI and we need the match count back in the find bar.
    private static let findScript = """
    (function () {
      var matches = [];
      function post(payload) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.folio) {
          window.webkit.messageHandlers.folio.postMessage(payload);
        }
      }
      window.folioClear = function () {
        matches = [];
        var marks = document.querySelectorAll('mark.folio-match');
        for (var i = 0; i < marks.length; i++) {
          var mark = marks[i];
          var parent = mark.parentNode;
          parent.replaceChild(document.createTextNode(mark.textContent), mark);
          parent.normalize();
        }
        return 0;
      };
      window.folioFind = function (query, caseSensitive) {
        window.folioClear();
        if (!query) { return 0; }
        var needle = caseSensitive ? query : query.toLowerCase();
        var root = document.getElementById('content');
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
          acceptNode: function (node) {
            if (!node.nodeValue || !node.nodeValue.trim()) { return NodeFilter.FILTER_REJECT; }
            var parent = node.parentElement;
            if (!parent || parent.offsetParent === null) { return NodeFilter.FILTER_REJECT; }
            // Lower-cased on purpose: mermaid injects <style> *inside* the SVG, where
            // tagName is lower case, and that CSS must never count as a match.
            var tag = (parent.tagName || '').toLowerCase();
            if (tag === 'script' || tag === 'style' || tag === 'noscript'
                || tag === 'title' || tag === 'defs') {
              return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        var targets = [];
        var current;
        while ((current = walker.nextNode())) { targets.push(current); }
        for (var i = 0; i < targets.length; i++) {
          var node = targets[i];
          var text = node.nodeValue;
          var haystack = caseSensitive ? text : text.toLowerCase();
          var from = 0, at;
          var pieces = [];
          while ((at = haystack.indexOf(needle, from)) !== -1) {
            pieces.push(at);
            from = at + needle.length;
          }
          if (!pieces.length) { continue; }
          var fragment = document.createDocumentFragment();
          var cursor = 0;
          for (var p = 0; p < pieces.length; p++) {
            var start = pieces[p];
            if (start > cursor) {
              fragment.appendChild(document.createTextNode(text.slice(cursor, start)));
            }
            var mark = document.createElement('mark');
            mark.className = 'folio-match';
            mark.textContent = text.slice(start, start + needle.length);
            fragment.appendChild(mark);
            matches.push(mark);
            cursor = start + needle.length;
          }
          if (cursor < text.length) {
            fragment.appendChild(document.createTextNode(text.slice(cursor)));
          }
          node.parentNode.replaceChild(fragment, node);
        }
        post({ type: 'matches', count: matches.length });
        return matches.length;
      };
      window.folioFocus = function (index) {
        if (!matches.length) { return -1; }
        var wrapped = ((index % matches.length) + matches.length) % matches.length;
        for (var i = 0; i < matches.length; i++) { matches[i].classList.remove('current'); }
        var target = matches[wrapped];
        target.classList.add('current');
        target.scrollIntoView({ block: 'center', behavior: 'smooth' });
        return wrapped;
      };
      window.folioScrollTo = function (anchor) {
        var element = document.getElementById(anchor);
        if (!element) { return false; }
        element.scrollIntoView({ block: 'start', behavior: 'smooth' });
        return true;
      };
      window.folioScrollToOffset = function (y) {
        window.scrollTo(0, y);
        return window.scrollY;
      };
      window.folioTopAnchor = function () {
        var headings = document.querySelectorAll('#content [id]');
        var best = '';
        for (var i = 0; i < headings.length; i++) {
          if (headings[i].getBoundingClientRect().top <= 24) { best = headings[i].id; }
        }
        return best;
      };
      // Throttled: the offset comes back with every report so the app can put the
      // reader back in place if the page is ever reloaded.
      var scrollTimer = null;
      document.addEventListener('scroll', function () {
        if (scrollTimer) { return; }
        scrollTimer = setTimeout(function () {
          scrollTimer = null;
          post({ type: 'anchor', anchor: window.folioTopAnchor(), scrollY: window.scrollY });
        }, 120);
      }, { passive: true });
    })();
    """

    // MARK: - Diagrams

    private static func diagramScript(isDark: Bool) -> String {
        """
        (function () {
          function post(payload) {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.folio) {
              window.webkit.messageHandlers.folio.postMessage(payload);
            }
          }
          if (typeof mermaid === 'undefined') {
            post({ type: 'diagrams', total: 0, failed: 0, error: 'mermaid did not load' });
            return;
          }
          mermaid.initialize({
            startOnLoad: false,
            securityLevel: 'strict',
            theme: '\(isDark ? "dark" : "default")',
            // Mermaid's own default puts a pale box behind edge labels, which reads as
            // a hole in dark mode; match the page's code background instead.
            themeVariables: {
              edgeLabelBackground: '\(isDark ? "#161b22" : "#f6f8fa")',
              fontSize: '14px'
            },
            fontFamily: '-apple-system, BlinkMacSystemFont, system-ui, sans-serif',
            flowchart: { useMaxWidth: true, htmlLabels: true },
            sequence: { useMaxWidth: true },
            gantt: { useMaxWidth: true }
          });
          var blocks = Array.prototype.slice.call(document.querySelectorAll('pre.mermaid'));
          var failed = 0;
          var pending = blocks.length;
          if (!pending) { post({ type: 'diagrams', total: 0, failed: 0 }); return; }
          blocks.forEach(function (block, index) {
            var source = block.textContent;
            mermaid.render('folio-diagram-' + index, source).then(function (result) {
              var holder = document.createElement('div');
              holder.className = 'diagram-rendered';
              holder.innerHTML = result.svg;
              block.replaceWith(holder);
              if (result.bindFunctions) { result.bindFunctions(holder); }
            }).catch(function (error) {
              failed += 1;
              var container = block.parentElement;
              container.classList.add('diagram-error');
              var message = document.createElement('div');
              message.className = 'diagram-message';
              message.textContent = 'Diagram could not be drawn — ' +
                ((error && error.message) ? error.message : String(error));
              container.insertBefore(message, container.firstChild);
              block.remove();
              var stray = document.getElementById('dfolio-diagram-' + index);
              if (stray) { stray.remove(); }
            }).finally(function () {
              pending -= 1;
              if (!pending) { post({ type: 'diagrams', total: blocks.length, failed: failed }); }
            });
          });
        })();
        """
    }

    /// Shown when the vendored mermaid bundle is missing from the app bundle.
    private static let missingMermaidScript = """
    (function () {
      var blocks = document.querySelectorAll('pre.mermaid');
      for (var i = 0; i < blocks.length; i++) {
        var container = blocks[i].parentElement;
        container.classList.add('diagram-error');
        var message = document.createElement('div');
        message.className = 'diagram-message';
        message.textContent = 'mermaid.min.js is missing from the app bundle, so the diagram source is shown instead.';
        container.insertBefore(message, container.firstChild);
        blocks[i].remove();
      }
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.folio) {
        window.webkit.messageHandlers.folio.postMessage({
          type: 'diagrams', total: blocks.length, failed: blocks.length, error: 'mermaid.min.js missing'
        });
      }
    })();
    """
}
