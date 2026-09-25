import Foundation
import Testing

@testable import Folio

/// The controls themselves run in the page, where a test on this machine cannot reach
/// them — `WKWebView` does not run without an `NSApplication`. What is checked here is
/// that the page is built to carry them and that they are wired to the moment the
/// diagrams finish drawing. The behaviour was checked by running the generated page in a
/// browser engine: zooming widens the SVG and the container scrolls, Fit puts the
/// stylesheet's own sizing back, and the full-window view moves the diagram out and
/// returns it with its inline zoom intact.
@Suite("Diagram controls")
struct DiagramControlsTests {

    private func page(diagrams: Int) -> String {
        HTMLPage.wrap(body: diagrams > 0 ? "<div class=\"diagram\"><pre class=\"mermaid\">flowchart TD\nA-->B</pre></div>"
                                         : "<p>no diagrams</p>",
                      title: "t", isDark: false,
                      mermaidScript: diagrams > 0 ? "/* mermaid */" : nil,
                      diagramCount: diagrams)
    }

    /// The script, not the stylesheet: the style rules are in every page either way,
    /// since the sheet is one block. It is the script that is left out.
    @Test func aDocumentWithoutDiagramsCarriesNoControls() {
        let html = page(diagrams: 0)
        #expect(!html.contains("folioAttachDiagramControls"))
        #expect(!html.contains("Fill the window"))
    }

    @Test func aDocumentWithADiagramCarriesTheControls() {
        let html = page(diagrams: 1)
        #expect(html.contains("window.folioAttachDiagramControls"))
        for title in ["Zoom out", "Zoom in", "Fit to the column", "Fill the window"] {
            #expect(html.contains(title))
        }
    }

    /// Quarter steps through the range anyone reads at. 100% to 150% in one press is too
    /// coarse to settle on a size with.
    @Test func zoomingStepsInQuarters() throws {
        let html = page(diagrams: 1)
        #expect(html.contains("[0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]"))
    }

    /// The level is a field, not a caption: stepping is for nudging, typing is for going
    /// somewhere. Anything unreadable puts the current level back.
    @Test func theLevelCanBeTypedInto() {
        let html = page(diagrams: 1)
        #expect(html.contains("field.type = 'text'"))
        #expect(html.contains("parseFloat(field.value.replace('%', '').trim())"))
        #expect(html.contains("if (!state.set(typed / 100)) { field.value = label(state); }"))
        // Out of range is clamped rather than refused.
        #expect(html.contains("Math.min(Math.max(scale, smallest), largest)"))
    }

    /// The full-window view treats + and - as zoom, which would otherwise eat them as
    /// they are typed into the level field. Its handler captures, so it has to look at
    /// what the key was aimed at.
    @Test func typingAPercentageIsNotTakenAsAShortcut() {
        #expect(page(diagrams: 1)
            .contains("if (event.target && event.target.className === 'diagram-zoom-level') { return; }"))
    }

    /// Mermaid draws asynchronously, so there is no SVG to put controls on until it has
    /// finished. They are attached where the count is reported, which is that moment.
    @Test func theControlsGoOnWhenTheDiagramsHaveBeenDrawn() throws {
        let html = page(diagrams: 1)
        let attach = try #require(html.range(of: "window.folioAttachDiagramControls();"))
        // The *final* report, the one carrying the count. There is an earlier one for
        // mermaid failing to load at all, and no diagram is drawn in that case.
        let report = try #require(html.range(of: "post({ type: 'diagrams', total: blocks.length"))
        // Same block, controls first: the count is the last thing said about a diagram.
        #expect(attach.lowerBound < report.lowerBound)
    }

    /// A diagram that failed to draw has no SVG and shows its source instead; putting a
    /// zoom control on it would offer to magnify an error message.
    @Test func aDiagramThatFailedToDrawGetsNoControls() {
        #expect(page(diagrams: 1).contains("if (!containers[i].classList.contains('diagram-error'))"))
    }

    @Test func theFullWindowViewCanBeClosedFromTheKeyboard() {
        let html = page(diagrams: 1)
        #expect(html.contains("event.key === 'Escape'"))
        // Capturing, so it closes this rather than whatever else listens for Escape.
        #expect(html.contains("document.addEventListener('keydown', onKey, true)"))
    }

    /// Zoom sets a width rather than a transform. A transform does not affect layout, so
    /// the container would not know the diagram had grown and nothing would scroll.
    @Test func zoomingResizesRatherThanTransforms() {
        let html = page(diagrams: 1)
        #expect(html.contains("svg.style.width = (naturalWidth(svg) * scale)"))
        #expect(!html.contains("transform: scale("))
    }

    @Test func theControlsAreStyledForBothThemes() {
        let html = page(diagrams: 1)
        #expect(html.contains(".diagram-controls"))
        #expect(html.contains(".folio-fullscreen"))
        // Colours come from the palette, so dark mode needs nothing of its own.
        #expect(html.contains("background: var(--bg); opacity: 0"))
    }
}
