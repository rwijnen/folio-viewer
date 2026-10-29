import Foundation

/// Folio Day and Folio Night: Mermaid's `base` theme, coloured from the page's own palette.
///
/// Mermaid's stock themes are a different design from the page around them — lavender
/// boxes and yellow notes by day, Mermaid's own dark by night — so a diagram read as
/// something pasted in. `base` is the one theme whose colours can all be replaced, and
/// these values are the stylesheet's: nodes take the page background, so they stand
/// out of the code-coloured box a diagram sits in; lines take the muted text colour;
/// the link blue is the one accent; series colours are the syntax palette.
///
/// A document that names its own theme keeps it — see `declaresOwnTheme`.
enum MermaidTheme {

    /// Variables in a fixed order, so the page source is the same every time.
    static func variables(isDark: Bool) -> [(key: String, value: String)] {
        isDark ? night : day
    }

    /// The `%%{init}%%` directive that applies the theme to one diagram's source.
    ///
    /// A directive rather than `mermaid.initialize`: variables given to `initialize`
    /// are laid over whatever theme a diagram chooses, so a document asking for `forest`
    /// would get Folio's colours anyway. As a directive, it is only added where the
    /// document has not chosen.
    static func directive(isDark: Bool) -> String {
        var config: [String: Any] = ["theme": "base"]
        var themeVariables: [String: Any] = [:]
        for (key, value) in variables(isDark: isDark) { themeVariables[key] = value }
        var json: [String: Any] = themeVariables
        // A flag, not a colour: as the string "false" it would read as true.
        json["darkMode"] = isDark
        config["themeVariables"] = json
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data()
        return "%%{init: \(String(decoding: data, as: UTF8.self))}%%"
    }

    // MARK: - Folio Day

    private static let day: [(key: String, value: String)] = [
        ("fontFamily", fontFamily),
        ("fontSize", "14px"),
        ("background", "#ffffff"),
        // Nodes
        ("primaryColor", "#ffffff"),
        ("primaryTextColor", "#1f2328"),
        ("primaryBorderColor", "#8c959f"),
        ("secondaryColor", "#ddf4ff"),
        ("secondaryTextColor", "#1f2328"),
        ("secondaryBorderColor", "#0969da"),
        ("tertiaryColor", "#eaeef2"),
        ("tertiaryTextColor", "#1f2328"),
        ("tertiaryBorderColor", "#d1d9e0"),
        ("mainBkg", "#ffffff"),
        ("nodeBorder", "#8c959f"),
        ("nodeTextColor", "#1f2328"),
        ("textColor", "#1f2328"),
        ("titleColor", "#1f2328"),
        ("lineColor", "#59636e"),
        ("clusterBkg", "#eaeef2"),
        ("clusterBorder", "#d1d9e0"),
        ("edgeLabelBackground", "#f6f8fa"),
        ("labelBackground", "#f6f8fa"),
        // Notes, in the page's highlight yellow
        ("noteBkgColor", "#fff8c5"),
        ("noteTextColor", "#1f2328"),
        ("noteBorderColor", "#d4a72c"),
        // Sequence
        ("actorBkg", "#ddf4ff"),
        ("actorBorder", "#0969da"),
        ("actorTextColor", "#1f2328"),
        ("actorLineColor", "#8c959f"),
        ("signalColor", "#59636e"),
        ("signalTextColor", "#1f2328"),
        ("labelBoxBkgColor", "#ffffff"),
        ("labelBoxBorderColor", "#8c959f"),
        ("labelTextColor", "#1f2328"),
        ("loopTextColor", "#1f2328"),
        ("activationBkgColor", "#ddf4ff"),
        ("activationBorderColor", "#0969da"),
        ("sequenceNumberColor", "#ffffff"),
        // Gantt
        ("sectionBkgColor", "#eaeef2"),
        ("altSectionBkgColor", "#ffffff"),
        ("sectionBkgColor2", "#ddf4ff"),
        ("taskBkgColor", "#ddf4ff"),
        ("taskBorderColor", "#0969da"),
        ("taskTextColor", "#1f2328"),
        ("taskTextLightColor", "#1f2328"),
        ("taskTextDarkColor", "#1f2328"),
        ("taskTextOutsideColor", "#1f2328"),
        ("taskTextClickableColor", "#0969da"),
        ("activeTaskBkgColor", "#b6e3ff"),
        ("activeTaskBorderColor", "#0969da"),
        ("doneTaskBkgColor", "#eaeef2"),
        ("doneTaskBorderColor", "#8c959f"),
        ("critBkgColor", "#ffebe9"),
        ("critBorderColor", "#cf222e"),
        ("todayLineColor", "#cf222e"),
        ("gridColor", "#d1d9e0"),
        // Errors
        ("errorBkgColor", "#ffebe9"),
        ("errorTextColor", "#cf222e"),
        // Entity–relationship rows
        ("attributeBackgroundColorOdd", "#ffffff"),
        ("attributeBackgroundColorEven", "#f6f8fa"),
    ] + series(strong: daySeries, soft: dayTints, text: "#1f2328", onStrong: "#ffffff",
               stroke: "#ffffff", outline: "#d1d9e0")

    // MARK: - Folio Night

    private static let night: [(key: String, value: String)] = [
        ("fontFamily", fontFamily),
        ("fontSize", "14px"),
        ("background", "#0d1117"),
        ("primaryColor", "#0d1117"),
        ("primaryTextColor", "#e6edf3"),
        ("primaryBorderColor", "#656c76"),
        ("secondaryColor", "#142339"),
        ("secondaryTextColor", "#e6edf3"),
        ("secondaryBorderColor", "#4493f8"),
        ("tertiaryColor", "#262c36"),
        ("tertiaryTextColor", "#e6edf3"),
        ("tertiaryBorderColor", "#3d444d"),
        ("mainBkg", "#0d1117"),
        ("nodeBorder", "#656c76"),
        ("nodeTextColor", "#e6edf3"),
        ("textColor", "#e6edf3"),
        ("titleColor", "#e6edf3"),
        ("lineColor", "#9198a1"),
        ("clusterBkg", "#262c36"),
        ("clusterBorder", "#3d444d"),
        ("edgeLabelBackground", "#161b22"),
        ("labelBackground", "#161b22"),
        // The page's night highlight, an amber wash, laid flat over the background:
        // Mermaid's colour maths reads hex only.
        ("noteBkgColor", "#3e331a"),
        ("noteTextColor", "#e6edf3"),
        ("noteBorderColor", "#9e6a03"),
        ("actorBkg", "#142339"),
        ("actorBorder", "#4493f8"),
        ("actorTextColor", "#e6edf3"),
        ("actorLineColor", "#656c76"),
        ("signalColor", "#9198a1"),
        ("signalTextColor", "#e6edf3"),
        ("labelBoxBkgColor", "#0d1117"),
        ("labelBoxBorderColor", "#656c76"),
        ("labelTextColor", "#e6edf3"),
        ("loopTextColor", "#e6edf3"),
        ("activationBkgColor", "#142339"),
        ("activationBorderColor", "#4493f8"),
        ("sequenceNumberColor", "#0d1117"),
        ("sectionBkgColor", "#262c36"),
        ("altSectionBkgColor", "#0d1117"),
        ("sectionBkgColor2", "#142339"),
        ("taskBkgColor", "#142339"),
        ("taskBorderColor", "#4493f8"),
        ("taskTextColor", "#e6edf3"),
        ("taskTextLightColor", "#e6edf3"),
        ("taskTextDarkColor", "#e6edf3"),
        ("taskTextOutsideColor", "#e6edf3"),
        ("taskTextClickableColor", "#4493f8"),
        ("activeTaskBkgColor", "#1f3d66"),
        ("activeTaskBorderColor", "#4493f8"),
        ("doneTaskBkgColor", "#262c36"),
        ("doneTaskBorderColor", "#656c76"),
        ("critBkgColor", "#301b1e"),
        ("critBorderColor", "#f85149"),
        ("todayLineColor", "#f85149"),
        ("gridColor", "#3d444d"),
        ("errorBkgColor", "#301b1e"),
        ("errorTextColor", "#f85149"),
        ("attributeBackgroundColorOdd", "#0d1117"),
        ("attributeBackgroundColorEven", "#161b22"),
    ] + series(strong: nightSeries, soft: nightTints, text: "#e6edf3", onStrong: "#0d1117",
               stroke: "#0d1117", outline: "#3d444d")

    // MARK: - Series

    /// The syntax palette: blue, orange, green, purple, red, cyan, yellow, pink.
    private static let daySeries = ["#0969da", "#bc4c00", "#1a7f37", "#8250df",
                                    "#cf222e", "#1b7c83", "#9a6700", "#bf3989"]
    private static let nightSeries = ["#4493f8", "#ffa657", "#3fb950", "#ab7df8",
                                      "#f85149", "#39c5cf", "#d29922", "#f778ba"]
    /// The same hues as washes, for areas with text on them: mindmap and timeline nodes.
    private static let dayTints = ["#ddf4ff", "#fff1e5", "#dafbe1", "#fbefff",
                                   "#ffebe9", "#d8f3f6", "#fff8c5", "#ffeff7"]
    private static let nightTints = ["#142339", "#31271f", "#152a20", "#252139",
                                     "#301b1e", "#142c33", "#2b2519", "#302130"]

    /// Pie slices, git branches, and the mindmap and timeline scale.
    private static func series(strong: [String], soft: [String], text: String,
                               onStrong: String, stroke: String, outline: String)
        -> [(key: String, value: String)] {
        var values: [(key: String, value: String)] = []
        // Twelve slices; past the eighth, the palette starts again.
        for index in 0..<12 {
            values.append(("pie\(index + 1)", strong[index % strong.count]))
        }
        values += [("pieStrokeColor", stroke), ("pieOuterStrokeColor", outline),
                   ("pieTitleTextColor", text), ("pieSectionTextColor", onStrong),
                   ("pieLegendTextColor", text)]
        for index in 0..<8 {
            values.append(("git\(index)", strong[index]))
            values.append(("gitBranchLabel\(index)", onStrong))
        }
        for index in 0..<12 {
            values.append(("cScale\(index)", soft[index % soft.count]))
            values.append(("cScaleLabel\(index)", text))
        }
        return values
    }

    private static let fontFamily = "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"

    // MARK: - A document's own choice

    /// A theme chosen in an `%%{init}%%` directive, or in front matter
    /// (`config:` / `theme: forest`). Shared with the page script, which applies them.
    static let ownThemePatterns = [
        #"%%\{[\s\S]*?["']?theme["']?\s*:[\s\S]*?\}%%"#,
        #"^\s*---[\s\S]*?\n\s*theme\s*:[\s\S]*?\n\s*---"#,
    ]

    /// Front matter at the top of a diagram, which has to stay first: the directive goes
    /// after it.
    static let frontMatterPattern = #"^\s*---[\s\S]*?\n\s*---[ \t]*(\n|$)"#

    /// Whether a diagram's source picks a theme itself. Those are left exactly as written.
    static func declaresOwnTheme(_ source: String) -> Bool {
        ownThemePatterns.contains { source.range(of: $0, options: .regularExpression) != nil }
    }

    /// The source as it is drawn: unchanged when it chose a theme, otherwise with Folio's
    /// directive added — after its front matter, if it has any. The page script does the
    /// same with the same patterns; this is the version the tests can reach.
    static func themed(_ source: String, isDark: Bool) -> String {
        if declaresOwnTheme(source) { return source }
        let line = directive(isDark: isDark) + "\n"
        if let range = source.range(of: frontMatterPattern, options: .regularExpression) {
            return String(source[..<range.upperBound]) + line + source[range.upperBound...]
        }
        return line + source
    }
}
