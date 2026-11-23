import AppKit

/// Draws the whole status item (symbol, optional text, optional red
/// background) into one image, so the item's width is fixed for a given text
/// and blinking only changes pixels, never layout.
enum StatusItemRenderer {
    static let symbolName = "dot.radiowaves.left.and.right"
    static let horizontalPadding: CGFloat = 5
    static let symbolTextSpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 4
    static let verticalInset: CGFloat = 2

    /// Menu-bar font with fixed-width digits so a ticking countdown never jitters.
    static func font() -> NSFont {
        let size = NSFont.menuBarFont(ofSize: 0).pointSize
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    static func symbolImage(color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: font().pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Broadcast")?
            .withSymbolConfiguration(config)
    }

    static func textSize(_ text: String) -> CGSize {
        (text as NSString).size(withAttributes: [.font: font()])
    }

    /// The size the image will have for `text`; identical for every flash
    /// state and blink phase, and for every string of equal length whose only
    /// differences are digits.
    static func size(for text: String?, height: CGFloat) -> CGSize {
        let symbolWidth = symbolImage(color: .black)?.size.width ?? height
        var width = horizontalPadding * 2 + symbolWidth
        if let text, !text.isEmpty {
            width += symbolTextSpacing + ceil(textSize(text).width)
        }
        return CGSize(width: ceil(width), height: height)
    }

    /// - Parameters:
    ///   - contentVisible: during a blink, `false` hides symbol and text and
    ///     leaves just the red background.
    /// - Returns: a template image (adapts to light/dark menu bars) when
    ///   `display.flash == .none`, otherwise a full-color image.
    static func image(for display: StatusItemDisplay, contentVisible: Bool = true, height: CGFloat) -> NSImage {
        let text = display.text
        let flashing = display.flash != .none
        let size = size(for: text, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            let contentColor: NSColor = flashing ? .white : .black

            if flashing {
                let background = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0, dy: verticalInset),
                    xRadius: cornerRadius, yRadius: cornerRadius
                )
                NSColor.systemRed.setFill()
                background.fill()
            }
            guard contentVisible || !flashing else { return true }

            var x = horizontalPadding
            if let symbol = symbolImage(color: contentColor) {
                let y = (rect.height - symbol.size.height) / 2
                symbol.draw(in: CGRect(x: x, y: y, width: symbol.size.width, height: symbol.size.height))
                x += symbol.size.width
            }
            if let text, !text.isEmpty {
                x += symbolTextSpacing
                let font = font()
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: contentColor]
                let textHeight = textSize(text).height
                let y = (rect.height - textHeight) / 2
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = !flashing
        image.accessibilityDescription = text ?? "Broadcast"
        return image
    }
}
