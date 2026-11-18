import AppKit
import SwiftUI

/// Renders the status item: glyph + live total. Plain states are template
/// images (macOS tints them for the menu bar); warning and stop states are
/// colored, which a plain SwiftUI label can't do in the menu bar.
enum StatusLabel {
    @MainActor
    static func image(text: String, color: NSColor?, dimmed: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let ink = (color ?? .black).withAlphaComponent(dimmed ? 0.45 : 1)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
        let textSize = string.size()
        let glyph: CGFloat = 15, gap: CGFloat = 4, height: CGFloat = 18
        let size = NSSize(width: ceil(glyph + gap + textSize.width), height: height)
        let path = GlyphShape().path(in: CGRect(x: 0, y: (height - glyph) / 2, width: glyph, height: glyph)).cgPath

        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path)
            ctx.setFillColor(ink.cgColor)
            ctx.fillPath()
            string.draw(at: NSPoint(x: glyph + gap, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}
