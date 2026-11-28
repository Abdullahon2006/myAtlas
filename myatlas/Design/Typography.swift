import SwiftUI

/// Role-based Dynamic Type scale.
/// Every style derives from a system text style so text scales up to AX5 and honors Bold Text.
extension Font {
    // MARK: Titles

    /// Top-level editorial brand title ("myatlas", "History").
    static let atlasDisplay = Font.system(.title, design: .serif).weight(.bold)
    /// Detail screen headline.
    static let detailTitle = Font.title2.bold()
    /// Toolbar or sheet header title.
    static let toolbarTitle = Font.headline

    // MARK: Lists & Cards

    /// Main title line of a row or card.
    static let rowTitle = Font.headline
    /// Secondary line of a row or card.
    static let rowSubtitle = Font.subheadline
    /// Trailing timestamp or metric label.
    static let rowDetail = Font.footnote
    /// Section label above grouped content (sentence/title case, never forced ALL CAPS).
    static let sectionLabel = Font.subheadline.weight(.semibold)

    // MARK: Reading

    /// Primary reading copy for notes and journal entries.
    static let bodyText = Font.body
    /// Supporting footer or metadata copy.
    static let note = Font.footnote

    // MARK: Controls & Identifiers

    /// Large action button label.
    static let buttonLabel = Font.headline
    /// Compact capsule count or status chip.
    static let badge = Font.caption.weight(.semibold)
    /// Coordinates and file identifiers.
    static let coordinate = Font.caption.monospacedDigit()

    // MARK: Symbols

    /// Standalone symbol in floating controls.
    static let symbolLarge = Font.title3.weight(.semibold)
    /// Standard symbol inside buttons and rows.
    static let symbol = Font.body.weight(.semibold)
    /// Compact badge symbol.
    static let symbolCompact = Font.caption.weight(.bold)
}
