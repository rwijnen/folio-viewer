import AppKit
import SwiftUI

/// Colours and metrics for the diff surface, in a GitHub-like palette that adapts
/// to light and dark appearance.
enum Theme {

    // MARK: - Dynamic colour helper

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    // MARK: - Diff backgrounds

    static let removedBackground = dynamic(light: hex(0xFFEBE9), dark: hex(0xF85149, alpha: 0.15))
    static let addedBackground = dynamic(light: hex(0xE6FFEC), dark: hex(0x3FB950, alpha: 0.15))
    static let removedWord = dynamic(light: hex(0xFFC1C0), dark: hex(0xF85149, alpha: 0.4))
    static let addedWord = dynamic(light: hex(0xABF2BC), dark: hex(0x3FB950, alpha: 0.4))
    static let fillerBackground = dynamic(light: hex(0xF6F8FA), dark: hex(0x0D1117))
    static let rowBackground = dynamic(light: hex(0xFFFFFF), dark: hex(0x161B22))

    static let removedGutter = dynamic(light: hex(0xFFD8D3), dark: hex(0xF85149, alpha: 0.25))
    static let addedGutter = dynamic(light: hex(0xCCFFD8), dark: hex(0x3FB950, alpha: 0.25))
    static let gutterBackground = dynamic(light: hex(0xF6F8FA), dark: hex(0x161B22))
    static let gutterText = dynamic(light: hex(0x8C959F), dark: hex(0x6E7681))
    static let border = dynamic(light: hex(0xD8DEE4), dark: hex(0x30363D))
    static let foldBackground = dynamic(light: hex(0xF0F6FC), dark: hex(0x1B2430))
    static let foldText = dynamic(light: hex(0x57606A), dark: hex(0x8B949E))

    static let searchMatch = dynamic(light: hex(0xFFF8C5), dark: hex(0xD29922, alpha: 0.45))
    static let currentSearchMatch = dynamic(light: hex(0xFFB454), dark: hex(0xE3852B, alpha: 0.85))

    // MARK: - Syntax colours

    static let codeText = dynamic(light: hex(0x1F2328), dark: hex(0xE6EDF3))

    static func color(for kind: TokenKind) -> Color {
        switch kind {
        case .keyword: return dynamic(light: hex(0xCF222E), dark: hex(0xFF7B72))
        case .type: return dynamic(light: hex(0x953800), dark: hex(0xFFA657))
        case .constant: return dynamic(light: hex(0x0550AE), dark: hex(0x79C0FF))
        case .string: return dynamic(light: hex(0x0A3069), dark: hex(0xA5D6FF))
        case .number: return dynamic(light: hex(0x0550AE), dark: hex(0x79C0FF))
        case .comment: return dynamic(light: hex(0x6E7781), dark: hex(0x8B949E))
        case .annotation: return dynamic(light: hex(0x8250DF), dark: hex(0xD2A8FF))
        }
    }

    // MARK: - Metrics

    static let fontSize: CGFloat = 12
    static let gutterWidth: CGFloat = 46
    static let markerWidth: CGFloat = 14
    static let codeFont = Font.system(size: fontSize, weight: .regular, design: .monospaced)
    static let uiFont = Font.system(size: 11)

    static var characterWidth: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }
}
