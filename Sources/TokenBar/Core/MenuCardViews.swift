import AppKit

/// Shared metrics for the drop-down's cards, so every row lines up on the same
/// left margin as the plain menu items below them.
enum MenuCard {
    /// Fixed width: the content is short and predictable, and a fixed width
    /// keeps the menu from resizing as numbers change.
    static let width: CGFloat = 280
    /// Roughly where AppKit starts a menu item's own text.
    static let inset: CGFloat = 21
    static let barHeight: CGFloat = 5

    static var bodyFont: NSFont { .menuFont(ofSize: 0) }
    static var captionFont: NSFont { .systemFont(ofSize: NSFont.smallSystemFontSize) }
    static var valueFont: NSFont {
        .monospacedDigitSystemFont(ofSize: MenuCard.bodyFont.pointSize, weight: .semibold)
    }
}

/// A provider's name at the head of its card.
///
/// Menu rows that carry information are disabled — they are not commands — and
/// AppKit draws a disabled item's title washed out however the title is
/// attributed. Drawing the row as a view instead sidesteps that entirely: the
/// text is ours, at the contrast we choose, and it still cannot be clicked.
@MainActor
final class MenuCardHeaderView: NSView {
    init(glyph: String, name: String, width: CGFloat = MenuCard.width) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))

        let label = NSTextField(labelWithString: "\(glyph)  \(name)")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: MenuCard.inset,
                             y: 7,
                             width: width - MenuCard.inset * 2,
                             height: 15)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override var isFlipped: Bool { true }
}

/// One `MenuRow`, drawn.
@MainActor
final class MenuCardRowView: NSView {
    init(row: MenuRow, width: CGFloat = MenuCard.width) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height(for: row)))

        let contentWidth = width - MenuCard.inset * 2

        switch row.kind {
        case .metric:
            let value = NSTextField(labelWithString: row.value)
            value.font = MenuCard.valueFont
            value.textColor = row.isWarning ? .systemRed : .labelColor
            value.alignment = .right
            value.frame = NSRect(x: MenuCard.inset, y: 4, width: contentWidth, height: 18)

            let label = NSTextField(labelWithString: row.label)
            label.font = MenuCard.bodyFont
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            // The value keeps its full width; the label yields the rest.
            let valueWidth = min(value.intrinsicContentSize.width, contentWidth)
            label.frame = NSRect(x: MenuCard.inset,
                                 y: 4,
                                 width: max(contentWidth - valueWidth - 8, 0),
                                 height: 18)

            addSubview(label)
            addSubview(value)

            if let fraction = row.fraction {
                let bar = UsageBarView(
                    frame: NSRect(x: MenuCard.inset,
                                  y: 26,
                                  width: contentWidth,
                                  height: MenuCard.barHeight),
                    fraction: fraction,
                    isWarning: row.isWarning)
                addSubview(bar)
            }

        case .caption, .notice:
            let label = NSTextField(labelWithString: row.label)
            label.font = MenuCard.captionFont
            label.textColor = row.kind == .notice ? .systemRed : .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: MenuCard.inset, y: 2, width: contentWidth, height: 15)
            addSubview(label)
        }

        setAccessibilityLabel(row.text)
        toolTip = row.text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override var isFlipped: Bool { true }

    /// Heights are fixed per row shape: every string here is one short line, so
    /// there is nothing to measure and nothing that reflows.
    nonisolated static func height(for row: MenuRow) -> CGFloat {
        switch row.kind {
        case .metric: return row.fraction == nil ? 26 : 26 + MenuCard.barHeight + 6
        case .caption, .notice: return 19
        }
    }
}

/// The share still available, as a rounded bar.
@MainActor
final class UsageBarView: NSView {
    private let fraction: Double
    private let isWarning: Bool

    init(frame: NSRect, fraction: Double, isWarning: Bool) {
        self.fraction = min(max(fraction, 0), 1)
        self.isWarning = isWarning
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard fraction > 0 else { return }
        // Round the fill up to at least its own height: a sliver has to read as
        // a sliver rather than as an empty track.
        let filled = max(bounds.width * CGFloat(fraction), bounds.height)
        (isWarning ? NSColor.systemRed : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: filled, height: bounds.height),
                     xRadius: radius,
                     yRadius: radius).fill()
    }
}
