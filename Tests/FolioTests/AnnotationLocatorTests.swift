import Foundation
import Testing

@testable import Folio

/// A selection made in the rendered view has lost the Markdown that produced it, so these
/// pin that it still finds its way home.
@Suite("Locating a selection")
struct AnnotationLocatorTests {

    private let source = [
        "# Sharing concept",                                     // 0
        "",                                                      // 1
        "Contacts carry **no channel**, editing is open to",      // 2
        "anyone who can [see them](./roles.md).",                 // 3
        "",                                                       // 4
        "- Direct reps see assigned accounts",                    // 5
        "- Indirect reps never see the dealer's end customer",    // 6
        "",                                                       // 7
        "Contacts carry **no channel**, editing is open to",      // 8
        "anyone who can see them.",                               // 9
    ]

    @Test func markersAndFurnitureAreNotWords() {
        #expect(AnnotationLocator.words("**bold** and _italic_") == "bold and italic")
        #expect(AnnotationLocator.words("- a bullet") == "a bullet")
        #expect(AnnotationLocator.words("1. numbered") == "numbered")
        #expect(AnnotationLocator.words("## A heading") == "A heading")
        #expect(AnnotationLocator.words("[label](http://x)") == "label")
        #expect(AnnotationLocator.words("  spaced   out  ") == "spaced out")
    }

    /// The rendered view gives "no channel", the source says "**no channel**".
    @Test func aSelectionInsideOneLineIsFound() {
        #expect(AnnotationLocator.locate(selection: "no channel", in: source) == 2...2)
    }

    @Test func aBulletIsFoundWithoutItsMarker() {
        #expect(AnnotationLocator.locate(selection: "Indirect reps never see", in: source) == 6...6)
    }

    /// A link renders as its label only.
    @Test func aLinkIsFoundByItsLabel() {
        #expect(AnnotationLocator.locate(selection: "see them", in: source) == 3...3)
    }

    /// The rendered paragraph is one flowing line; the source is wrapped.
    @Test func aSelectionAcrossWrappedLinesSpansThem() {
        let found = AnnotationLocator.locate(
            selection: "editing is open to anyone who can see them", in: source)
        #expect(found == 2...3)
    }

    /// The same sentence appears twice. The hint says which one was selected.
    @Test func theHintChoosesBetweenRepeatedPassages() {
        #expect(AnnotationLocator.locate(selection: "no channel", in: source, hint: 8) == 8...8)
        #expect(AnnotationLocator.locate(selection: "no channel", in: source, hint: 2) == 2...2)
        // With no hint at all, the first is a defensible answer rather than a wrong one.
        #expect(AnnotationLocator.locate(selection: "no channel", in: source) == 2...2)
    }

    @Test func somethingThatIsNotThereIsNotInvented() {
        #expect(AnnotationLocator.locate(selection: "a phrase never written", in: source) == nil)
        #expect(AnnotationLocator.locate(selection: "   ", in: source) == nil)
        #expect(AnnotationLocator.locate(selection: "anything", in: []) == nil)
    }

    @Test func aWholeHeadingIsFound() {
        #expect(AnnotationLocator.locate(selection: "Sharing concept", in: source) == 0...0)
    }
}
