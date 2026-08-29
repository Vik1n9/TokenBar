import Foundation

/// One line of a provider's card in the drop-down.
///
/// Providers describe what a line *is* rather than handing over a finished
/// string, so the menu can draw a number differently from the sentence under it
/// — a value gets its own weight and a bar, context stays quiet.
struct MenuRow: Equatable {
    enum Kind: Equatable {
        /// A number worth reading at a glance: `7-day allowance   42% left`.
        case metric
        /// Context under a metric: when it resets, which rate band is running.
        case caption
        /// Something the user may need to act on.
        case notice
    }

    let kind: Kind
    let label: String
    /// Right-aligned value; empty for captions and notices.
    let value: String
    /// 0…1 share still available, drawn as a bar under a metric. nil when the
    /// number is not a ratio — a currency balance has no full mark.
    let fraction: Double?
    let isWarning: Bool

    static func metric(_ label: String,
                       _ value: String,
                       fraction: Double? = nil,
                       isWarning: Bool = false) -> MenuRow {
        MenuRow(kind: .metric, label: label, value: value, fraction: fraction, isWarning: isWarning)
    }

    static func caption(_ text: String) -> MenuRow {
        MenuRow(kind: .caption, label: text, value: "", fraction: nil, isWarning: false)
    }

    static func notice(_ text: String) -> MenuRow {
        MenuRow(kind: .notice, label: text, value: "", fraction: nil, isWarning: true)
    }

    /// Flat text form, for the self-check and for anywhere a row has to be
    /// printed rather than drawn.
    var text: String {
        value.isEmpty ? label : "\(label): \(value)"
    }
}
