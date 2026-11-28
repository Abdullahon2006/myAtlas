import SwiftUI
import UIKit

/// Adaptive Cartographer's Field Journal color palette.
/// Every foreground/background pair is tuned for >= 4.5:1 contrast in both Light and Dark Mode.
extension Color {
    // MARK: Surfaces

    /// Main canvas: warm archival paper in Light Mode, deep slate-forest in Dark Mode.
    static let atlasCanvas = Color(
        light: UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1),
        dark: UIColor(red: 0.07, green: 0.09, blue: 0.08, alpha: 1)
    )

    /// Elevated card surface.
    static let atlasSurface = Color(
        light: UIColor(red: 1.0, green: 0.995, blue: 0.98, alpha: 1),
        dark: UIColor(red: 0.12, green: 0.14, blue: 0.13, alpha: 1)
    )

    /// Subtle secondary surface for timeline rails and empty frames.
    static let atlasMist = Color(
        light: UIColor(red: 0.85, green: 0.88, blue: 0.83, alpha: 1),
        dark: UIColor(red: 0.16, green: 0.20, blue: 0.18, alpha: 1)
    )

    /// Rounded fill behind input controls.
    static let atlasFieldFill = Color(uiColor: .tertiarySystemFill)

    // MARK: Identity & Semantic Ink

    /// Primary ink: deep forest charcoal in Light Mode, warm ivory in Dark Mode.
    static let atlasInk = Color(
        light: UIColor(red: 0.08, green: 0.12, blue: 0.11, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.93, blue: 0.89, alpha: 1)
    )

    /// Botanical moss accent for text/icons (> 7:1 contrast on light surfaces, bright sage in Dark Mode).
    static let atlasMoss = Color(
        light: UIColor(red: 0.16, green: 0.34, blue: 0.20, alpha: 1),
        dark: UIColor(red: 0.45, green: 0.78, blue: 0.52, alpha: 1)
    )

    /// Terracotta clay accent for text/icons (> 5.1:1 contrast on light surfaces, warm coral in Dark Mode).
    static let atlasClay = Color(
        light: UIColor(red: 0.67, green: 0.24, blue: 0.13, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.54, blue: 0.42, alpha: 1)
    )

    /// Ochre amber for favorites & ratings.
    static let atlasAmber = Color(
        light: UIColor(red: 0.58, green: 0.35, blue: 0.02, alpha: 1),
        dark: UIColor(red: 0.96, green: 0.75, blue: 0.26, alpha: 1)
    )

    /// Slate blue for culture/info.
    static let atlasSlate = Color(
        light: UIColor(red: 0.12, green: 0.35, blue: 0.56, alpha: 1),
        dark: UIColor(red: 0.44, green: 0.70, blue: 0.94, alpha: 1)
    )

    /// Indigo accent tuned for >= 4.5:1 text contrast in both appearances.
    static let atlasIndigo = Color(
        light: UIColor(red: 0.24, green: 0.22, blue: 0.65, alpha: 1),
        dark: UIColor(red: 0.62, green: 0.60, blue: 0.98, alpha: 1)
    )

    // MARK: High-Contrast Button & Chip Tokens

    /// Selected chip / prominent dark control fill; pair with `atlasSelectedForeground`.
    static let atlasSelectedBackground = atlasInk
    /// Foreground text on `atlasSelectedBackground` (white in Light Mode, charcoal in Dark Mode).
    static let atlasSelectedForeground = Color(
        light: UIColor.white,
        dark: UIColor(red: 0.08, green: 0.12, blue: 0.11, alpha: 1)
    )

    /// Deep terracotta fill guaranteed >= 5.2:1 with `.white` text in both Light and Dark Mode.
    static let atlasPrimaryButton = Color(
        light: UIColor(red: 0.67, green: 0.24, blue: 0.13, alpha: 1),
        dark: UIColor(red: 0.60, green: 0.19, blue: 0.09, alpha: 1)
    )

    /// Deep moss fill guaranteed >= 7:1 with `.white` text in both Light and Dark Mode.
    static let atlasMossButton = Color(
        light: UIColor(red: 0.13, green: 0.30, blue: 0.17, alpha: 1),
        dark: UIColor(red: 0.15, green: 0.35, blue: 0.20, alpha: 1)
    )

    /// Hairline border that remains legible in both appearances.
    static let atlasHairline = Color(
        light: UIColor(red: 0.08, green: 0.12, blue: 0.11, alpha: 0.12),
        dark: UIColor(red: 0.94, green: 0.93, blue: 0.89, alpha: 0.16)
    )

    /// High-contrast border when Increase Contrast is enabled.
    static let atlasContrastBorder = Color(
        light: UIColor(red: 0.08, green: 0.12, blue: 0.11, alpha: 0.45),
        dark: UIColor(red: 0.94, green: 0.93, blue: 0.89, alpha: 0.55)
    )

    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension PlaceCategory {
    /// Text & badge foreground tint (>= 4.5:1 against `atlasCanvas`/`atlasSurface` in both appearances).
    var tintColor: Color {
        switch self {
        case .viewpoint: .atlasClay
        case .food: .atlasAmber
        case .nature: .atlasMoss
        case .culture: .atlasSlate
        case .stay: .atlasIndigo
        case .gem: Color(light: UIColor(red: 0.45, green: 0.18, blue: 0.56, alpha: 1), dark: UIColor(red: 0.80, green: 0.55, blue: 0.95, alpha: 1))
        case .note: .atlasMoss
        }
    }

    /// Rich saturated fill for white symbols on map pins and icon tiles (>= 4.5:1 with `.white` in Light and Dark Mode).
    var pinFillColor: Color {
        switch self {
        case .viewpoint: .atlasPrimaryButton
        case .food: Color(light: UIColor(red: 0.58, green: 0.35, blue: 0.02, alpha: 1), dark: UIColor(red: 0.55, green: 0.32, blue: 0.02, alpha: 1))
        case .nature: .atlasMossButton
        case .culture: Color(light: UIColor(red: 0.12, green: 0.35, blue: 0.56, alpha: 1), dark: UIColor(red: 0.12, green: 0.35, blue: 0.56, alpha: 1))
        case .stay: Color(light: UIColor(red: 0.24, green: 0.22, blue: 0.65, alpha: 1), dark: UIColor(red: 0.24, green: 0.22, blue: 0.65, alpha: 1))
        case .gem: Color(light: UIColor(red: 0.45, green: 0.18, blue: 0.56, alpha: 1), dark: UIColor(red: 0.43, green: 0.17, blue: 0.54, alpha: 1))
        case .note: .atlasMossButton
        }
    }
}
