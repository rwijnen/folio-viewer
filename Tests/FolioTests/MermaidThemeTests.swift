import Foundation
import Testing

@testable import Folio

/// Folio Day and Folio Night. The colours themselves were judged by eye in WebKit; what
/// is pinned here is what would quietly break them: a value Mermaid cannot read, text
/// that cannot be read on its fill, and a document's own theme being overridden.
@Suite("Mermaid theme")
struct MermaidThemeTests {

    private func lookup(_ isDark: Bool) -> [String: String] {
        Dictionary(MermaidTheme.variables(isDark: isDark).map { ($0.key, $0.value) },
                   uniquingKeysWith: { first, _ in first })
    }

    @Test func bothThemesSetTheSameVariablesOnce() {
        let day = MermaidTheme.variables(isDark: false).map(\.key)
        let night = MermaidTheme.variables(isDark: true).map(\.key)
        #expect(day == night)
        #expect(Set(day).count == day.count)
    }

    /// Mermaid's colour maths reads `#rrggbb`; a name or an `rgba()` comes out wrong.
    @Test func everyColourIsSixDigitHex() {
        for isDark in [false, true] {
            for (key, value) in MermaidTheme.variables(isDark: isDark)
            where key != "fontFamily" && key != "fontSize" {
                #expect(value.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil,
                        "\(key) = \(value)")
            }
        }
    }

    /// WCAG AA for body text, on every fill that carries words.
    @Test func textIsReadableOnItsFill() throws {
        let pairs = [("primaryTextColor", "primaryColor"), ("nodeTextColor", "mainBkg"),
                     ("primaryTextColor", "clusterBkg"), ("textColor", "edgeLabelBackground"),
                     ("noteTextColor", "noteBkgColor"), ("actorTextColor", "actorBkg"),
                     ("taskTextColor", "taskBkgColor"), ("taskTextDarkColor", "activeTaskBkgColor"),
                     ("taskTextColor", "doneTaskBkgColor"), ("taskTextColor", "critBkgColor"),
                     ("textColor", "rowOdd"), ("textColor", "rowEven"),
                     ("errorTextColor", "errorBkgColor")]
            + (0..<12).map { ("cScaleLabel\($0)", "cScale\($0)") }
        for isDark in [false, true] {
            let theme = lookup(isDark)
            for (text, fill) in pairs {
                let ratio = try contrast(#require(theme[text]), try #require(theme[fill]))
                #expect(ratio >= 4.5, "\(isDark ? "night" : "day"): \(text) on \(fill) is \(ratio)")
            }
        }
    }

    /// Edge labels sit on the diagram box, which is the page's code background.
    @Test func edgeLabelsMatchTheDiagramBox() {
        #expect(lookup(false)["edgeLabelBackground"] == "#f6f8fa")
        #expect(lookup(true)["edgeLabelBackground"] == "#161b22")
    }

    @Test func theDirectiveIsJSONMermaidCanRead() throws {
        for isDark in [false, true] {
            let directive = MermaidTheme.directive(isDark: isDark)
            #expect(directive.hasPrefix("%%{init: ") && directive.hasSuffix("}%%"))
            #expect(!directive.dropLast(3).contains("}%%"))
            let json = directive.dropFirst("%%{init: ".count).dropLast(3)
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(object["theme"] as? String == "base")
            let variables = try #require(object["themeVariables"] as? [String: Any])
            // A boolean, not the string "false", which JavaScript reads as true.
            #expect(variables["darkMode"] as? Bool == isDark)
            #expect(variables["primaryColor"] as? String == (isDark ? "#0d1117" : "#ffffff"))
        }
    }

    // MARK: A document's own choice

    @Test func aPlainDiagramGetsFolioTheme() {
        let themed = MermaidTheme.themed("flowchart LR\n  A --> B", isDark: false)
        #expect(themed.hasPrefix(MermaidTheme.directive(isDark: false) + "\n"))
        #expect(themed.hasSuffix("flowchart LR\n  A --> B"))
    }

    @Test func aThemeTheDocumentChoseIsKept() {
        let directive = "%%{init: {'theme': 'forest'}}%%\nflowchart LR\n  A --> B"
        #expect(MermaidTheme.themed(directive, isDark: true) == directive)
        let quoted = "%%{init: {\"theme\":\"neutral\"}}%%\ngraph TD\n  A"
        #expect(MermaidTheme.themed(quoted, isDark: false) == quoted)
        let frontMatter = "---\nconfig:\n  theme: dark\n---\nflowchart LR\n  A --> B"
        #expect(MermaidTheme.themed(frontMatter, isDark: false) == frontMatter)
    }

    /// Front matter has to stay first, or Mermaid stops reading it as front matter.
    @Test func frontMatterStaysOnTop() {
        let source = "---\ntitle: Flow\n---\nflowchart LR\n  A --> B"
        let themed = MermaidTheme.themed(source, isDark: true)
        #expect(themed.hasPrefix("---\ntitle: Flow\n---\n%%{init: "))
        #expect(themed.hasSuffix("}%%\nflowchart LR\n  A --> B"))
    }

    /// Other init settings do not count as choosing a theme.
    @Test func aDirectiveWithoutAThemeStillGetsFolios() {
        let source = "%%{init: {'flowchart': {'curve': 'step'}}}%%\nflowchart LR\n  A --> B"
        #expect(MermaidTheme.themed(source, isDark: false) != source)
    }

    @Test func thePageAppliesTheTheme() {
        for isDark in [false, true] {
            let page = HTMLPage.wrap(body: "<pre class=\"mermaid\">graph TD\nA</pre>", title: "t",
                                     isDark: isDark, mermaidScript: "/* mermaid */", diagramCount: 1)
            #expect(page.contains("var source = themed(block.textContent);"))
            #expect(page.contains(isDark ? "#3e331a" : "#fff8c5"))
            #expect(page.contains("forest") == false)
        }
    }

    /// Boxes are rounded: rectangles by the stylesheet, class boxes and ER tables, which
    /// Mermaid draws as paths, by the script once each diagram is drawn.
    @Test func boxesAreRounded() {
        let page = HTMLPage.wrap(body: "<pre class=\"mermaid\">graph TD\nA</pre>", title: "t",
                                 isDark: false, mermaidScript: "/* mermaid */", diagramCount: 1)
        #expect(page.contains(".diagram-rendered .node rect.label-container"))
        #expect(page.contains("rx: 6px; ry: 6px;"))
        #expect(page.contains("roundClassBoxes(holder);"))
        #expect(page.contains("g.node > g.outer-path"))
        // The rows of an ER table would otherwise square its corners off again.
        #expect(page.contains("g.row-rect-odd, :scope > g.row-rect-even"))
    }

    @Test func nodesAreOutlinedInTheCalloutTeal() {
        #expect(lookup(false)["nodeBorder"] == "#1b7c83")
        #expect(lookup(true)["nodeBorder"] == "#2a9fa8")
    }

    // MARK: Contrast

    private func contrast(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func luminance(_ hex: String) -> Double {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        let channels = [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff].map { raw -> Double in
            let c = Double(raw) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}
