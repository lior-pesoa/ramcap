import AppKit
import SwiftUI

/// Colors from the Figma `RAMcap` variable collection (Light / Dark modes).
enum Palette {
    static let panel = Color(light: 0xF4F4F6, dark: 0x1F1F22)
    static let track = Color(light: 0xE3E3E8, dark: 0x38383C)
    static let separator = Color(light: 0xE2E2E6, dark: 0x34343A)
    static let primary = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let secondary = Color(light: 0x6E6E73, dark: 0xA1A1A6)
    static let tertiary = Color(light: 0xA1A1A6, dark: 0x6E6E73)
    static let cap = Color(light: 0xF2512F, dark: 0xFF6342)
    static let ok = Color(light: 0x28A745, dark: 0x30D158)
    static let warn = Color(light: 0xD97A00, dark: 0xFFB340)
    static let danger = Color(light: 0xE5312B, dark: 0xFF453A)
    static let tintOK = Color(light: 0xE2F3E6, dark: 0x1C3524)
    static let tintWarn = Color(light: 0xFAEBD5, dark: 0x3B2E1C)
    static let tintDanger = Color(light: 0xFBE2E0, dark: 0x46211E)
    static let tintNeutral = Color(light: 0xE6E6EB, dark: 0x34343A)

    /// Menu bar label colors (fixed: they sit on the menu bar, not the panel).
    static let menuWarn = NSColor(hex: 0xFFB340)
    static let menuDanger = NSColor(hex: 0xFF453A)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

/// The menu bar glyph: a cap line over three bars, the tallest pressed flat
/// against it. Drawn on an 18 × 18 grid (same as the Figma component).
struct GlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 18
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> Path {
            Path(roundedRect: CGRect(x: rect.minX + x * s, y: rect.minY + y * s, width: w * s, height: h * s),
                 cornerRadius: radius * s)
        }
        var p = Path()
        p.addPath(r(1, 2, 16, 2.4, 1.2))
        p.addPath(r(2.6, 11, 3.2, 5, 1))
        p.addPath(r(7.4, 8, 3.2, 8, 1))
        // Tallest bar: flat top against the cap, rounded bottom.
        p.addPath(Path(roundedRect: CGRect(x: rect.minX + 12.2 * s, y: rect.minY + 5.6 * s, width: 3.2 * s, height: 10.4 * s),
                       cornerRadii: .init(topLeading: 0, bottomLeading: s, bottomTrailing: s, topTrailing: 0)))
        return p
    }
}
