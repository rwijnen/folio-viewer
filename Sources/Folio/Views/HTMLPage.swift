import Foundation

/// Wraps converted markdown in a self-contained HTML page.
///
/// The page is locked down: a strict CSP with a per-load nonce means the only script
/// that can run is the bundled mermaid bootstrap, nothing can be fetched over the
/// network, and images only load from the `data:` URIs the converter inlined.
enum HTMLPage {

    /// How wide the rendered page's column of text may grow, in CSS pixels.
    ///
    /// A reading measure rather than a window width: past a point the eye loses its place
    /// coming back to the start of the next line, so the column stays centred and the
    /// window can be as wide as you like. At the page's 14px body text this is roughly 110
    /// characters — generous for plain prose, and deliberately so, because these documents
    /// carry tables, code fences and diagrams that were being squeezed at the old 860.
    static let readingWidth = 990


    static func wrap(body: String, title: String, isDark: Bool,
                     mermaidScript: String?, diagramCount: Int,
                     annotated: [AnnotatedPassage] = []) -> String {
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
        scripts += "<script nonce=\"\(nonce)\">\(selectionScript)</script>"
        scripts += "<script nonce=\"\(nonce)\">\(annotationScript(annotated))</script>"
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
      --annotated: #fff4e5; --annotated-edge: #e8a33d;
    }
    html[data-theme="dark"] {
      --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --border: #3d444d;
      --code-bg: #161b22; --quote-border: #3d444d; --link: #4493f8;
      --table-stripe: #161b22; --mark: rgba(210,153,34,.45); --mark-current: #e3852b;
      --tk-keyword: #ff7b72; --tk-type: #ffa657; --tk-constant: #79c0ff;
      --annotated: rgba(232,163,61,.16); --annotated-edge: #b1760f;
      --tk-string: #a5d6ff; --tk-number: #79c0ff; --tk-comment: #8b949e;
      --tk-annotation: #d2a8ff; --error-bg: #3b2300; --error-fg: #ffb77c;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--fg);
      font: 14px/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      -webkit-font-smoothing: antialiased;
    }
    #content { max-width: \(readingWidth)px; margin: 0 auto; padding: 28px 32px 80px; }
    /* The words a note or change request was left against. A wash and an underline
       rather than a border, so it is visible while reading without breaking the line. */
    mark.folio-annotated {
      background: var(--annotated); color: inherit; border-radius: 2px;
      box-shadow: 0 1px 0 0 var(--annotated-edge);
    }
    /* Only when the words cannot be found in the rendered page — an annotation left
       against source that renders to something else, say a table cell reflowed away. */
    .folio-annotated-block {
      background: var(--annotated); border-radius: 3px;
      box-shadow: -4px 0 0 0 var(--annotated-edge);
    }
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
      // While a chosen heading is being scrolled to, the page reports that heading
      // rather than whatever is passing the top of the window — otherwise the outline's
      // selection walks down the list during the animation and only then settles.
      var pinned = null, quiet = null;
      window.folioScrollTo = function (anchor) {
        var element = document.getElementById(anchor);
        if (!element) { return false; }
        pinned = anchor;
        // Released on a timer as well as by the page going quiet: a heading already at
        // the top scrolls nowhere, no scroll event ever fires, and the pin would then
        // hold the outline on that heading for the rest of the session.
        if (quiet) { clearTimeout(quiet); }
        quiet = setTimeout(function () { quiet = null; pinned = null; }, 1200);
        element.scrollIntoView({ block: 'start', behavior: 'smooth' });
        return true;
      };
      // Which source line the page is showing, for keeping an editor beside it in step.
      // Blocks carry `data-line` already — headings always did, paragraphs since notes
      // were added — so this is a question the page can answer without being told
      // anything new about the document.
      window.folioTopLine = function () {
        var blocks = document.querySelectorAll('#content [data-line]');
        var best = null;
        for (var i = 0; i < blocks.length; i++) {
          if (blocks[i].getBoundingClientRect().top <= 24) {
            var line = parseInt(blocks[i].getAttribute('data-line'), 10);
            if (!isNaN(line)) { best = line; }
          }
        }
        return best;
      };
      // The reverse: put the block covering this source line at the top. Nearest at or
      // above, because most lines are inside a block rather than starting one.
      window.folioScrollToLine = function (line) {
        var blocks = document.querySelectorAll('#content [data-line]');
        var target = null;
        for (var i = 0; i < blocks.length; i++) {
          var at = parseInt(blocks[i].getAttribute('data-line'), 10);
          if (isNaN(at)) { continue; }
          if (at <= line) { target = blocks[i]; } else { break; }
        }
        if (!target) { window.scrollTo(0, 0); return true; }
        // Not scrollIntoView: that animates, and an editor being scrolled alongside does
        // not, so the two would visibly disagree for the length of the animation.
        var top = target.getBoundingClientRect().top + window.scrollY - 12;
        window.scrollTo(0, Math.max(0, top));
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
        // The animation is over when the scrolling stops; there is no event for it.
        if (pinned) {
          post({ type: 'anchor', anchor: pinned, scrollY: window.scrollY });
          if (quiet) { clearTimeout(quiet); }
          quiet = setTimeout(function () { quiet = null; pinned = null; }, 150);
          return;
        }
        if (scrollTimer) { return; }
        scrollTimer = setTimeout(function () {
          scrollTimer = null;
          post({ type: 'anchor', anchor: window.folioTopAnchor(),
                 line: window.folioTopLine(), scrollY: window.scrollY });
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

extension HTMLPage {

    /// Reports the selection to the app as it changes.
    ///
    /// Continuously, rather than when the context menu opens: the menu is built by AppKit
    /// and there is no moment in that sequence to ask the page a question and wait for the
    /// answer. By the time the menu is wanted, the app already knows.
    static let selectionScript = """
    (function () {
      var last = '', timer = null;
      function lineOf(node) {
        var el = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
        while (el) {
          if (el.hasAttribute && el.hasAttribute('data-line')) {
            return parseInt(el.getAttribute('data-line'), 10);
          }
          el = el.parentElement;
        }
        return null;
      }
      function report() {
        var sel = window.getSelection();
        var text = sel ? String(sel) : '';
        if (text === last) { return; }
        last = text;
        var line = null;
        if (sel && sel.rangeCount > 0) { line = lineOf(sel.getRangeAt(0).startContainer); }
        if (window.webkit && window.webkit.messageHandlers
            && window.webkit.messageHandlers.folio) {
          window.webkit.messageHandlers.folio.postMessage(
            { type: 'selection', text: text, line: line });
        }
      }
      document.addEventListener('selectionchange', function () {
        // Coalesced: this fires on every tick of a drag.
        if (timer) { clearTimeout(timer); }
        timer = setTimeout(report, 120);
      });
    })();
    """

    /// One passage the reader marked up: where it is in the source, and the words as
    /// the page renders them.
    struct AnnotatedPassage: Equatable {
        var lines: ClosedRange<Int>
        /// The selection as it was made, which is the rendered text rather than the
        /// Markdown behind it — `see them` where the source says `[see them](./x.md)`.
        var quote: String
    }

    /// Marks the words a note or change request was left against.
    ///
    /// The words, not the block they sit in. The quote was taken from the rendered page
    /// in the first place, so it can be found there again — including where it runs
    /// across a link or a bold run, which is why this walks text nodes and builds one
    /// string per block rather than searching each node on its own.
    ///
    /// Whitespace is flattened on both sides before comparing: the source wraps its
    /// paragraphs, and the selection does not come back with those newlines in it.
    static func annotationScript(_ passages: [AnnotatedPassage]) -> String {
        guard !passages.isEmpty else { return "" }
        let payload = passages.map {
            [$0.lines.lowerBound, $0.lines.upperBound, $0.quote] as [Any]
        }
        // Slashes unescaped: a quote can contain a path or a URL, and `\/` throughout
        // makes the script unreadable when anyone comes to look at it.
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        // `<` cannot reach the page raw: `</script>` inside a quote would end the script.
        // Inside JSON these only ever occur within string literals, where \u003c is `<`.
        let safe = json.replacingOccurrences(of: "<", with: "\\u003c")
        return """
        (function () {
          var passages = \(safe);

          function flatten(text) { return text.replace(/\\s+/g, ' ').trim(); }

          // The block's text nodes as one string, with a way back from any index in the
          // flattened version to a node and an offset inside it.
          function index(root) {
            var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
            var spans = [], raw = '', node;
            while ((node = walker.nextNode())) {
              spans.push({ node: node, at: raw.length });
              raw += node.nodeValue;
            }
            var flat = '', back = [], space = true;
            for (var i = 0; i < raw.length; i++) {
              var ch = raw[i];
              if (ch === ' ' || ch === '\\n' || ch === '\\t' || ch === '\\r') {
                if (space) { continue; }
                space = true; flat += ' '; back.push(i);
              } else {
                space = false; flat += ch; back.push(i);
              }
            }
            return { spans: spans, flat: flat, back: back };
          }

          function at(ix, rawIndex) {
            for (var i = ix.spans.length - 1; i >= 0; i--) {
              if (rawIndex >= ix.spans[i].at) {
                return { node: ix.spans[i].node, offset: rawIndex - ix.spans[i].at };
              }
            }
            return null;
          }

          function mark(block, needle) {
            var ix = index(block);
            var found = ix.flat.indexOf(needle);
            if (found === -1 || !needle) { return false; }
            var startRaw = ix.back[found];
            var endRaw = ix.back[found + needle.length - 1] + 1;
            var from = at(ix, startRaw), to = at(ix, endRaw);
            if (!from || !to) { return false; }
            var range = document.createRange();
            try {
              range.setStart(from.node, from.offset);
              range.setEnd(to.node, to.offset);
            } catch (e) { return false; }
            var element = document.createElement('mark');
            element.className = 'folio-annotated';
            try {
              range.surroundContents(element);
            } catch (e) {
              // The range crosses an element boundary, so it cannot simply be wrapped.
              try {
                element.appendChild(range.extractContents());
                range.insertNode(element);
              } catch (e2) { return false; }
            }
            return true;
          }

          var blocks = document.querySelectorAll('#content [data-line]');
          for (var p = 0; p < passages.length; p++) {
            var from = passages[p][0], to = passages[p][1];
            var needle = flatten(passages[p][2]);
            var candidates = [];
            for (var b = 0; b < blocks.length; b++) {
              var line = parseInt(blocks[b].getAttribute('data-line'), 10);
              if (!isNaN(line) && line >= from && line <= to) { candidates.push(blocks[b]); }
            }
            var done = false;
            for (var c = 0; c < candidates.length && !done; c++) {
              done = mark(candidates[c], needle);
            }
            if (!done) {
              // Say something rather than nothing: the note exists either way.
              for (var f = 0; f < candidates.length; f++) {
                candidates[f].classList.add('folio-annotated-block');
              }
            }
          }
        })();
        """
    }
}
