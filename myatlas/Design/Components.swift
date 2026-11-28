import SwiftUI
import UIKit

/// Switches horizontal layouts to vertical at accessibility text sizes while preserving view identity.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var alignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: alignment, spacing: spacing))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
    }
}

/// Applies adaptive floating chrome that respects Reduce Transparency and Increase Contrast.
struct FloatingChromeModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S

    func body(content: Content) -> some View {
        let fillStyle = reduceTransparency ? AnyShapeStyle(Color.atlasSurface) : AnyShapeStyle(.regularMaterial)
        let borderColor = contrast == .increased ? Color.atlasContrastBorder : Color.atlasHairline
        let borderWidth: CGFloat = contrast == .increased ? 1.5 : 1

        content
            .background(shape.fill(fillStyle))
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
    }
}

extension View {
    func floatingChrome<S: InsettableShape>(in shape: S) -> some View {
        modifier(FloatingChromeModifier(shape: shape))
    }

    func cardSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

private struct CardSurfaceModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color.atlasSurface, in: shape)
            .overlay(
                shape.strokeBorder(
                    contrast == .increased ? Color.atlasContrastBorder : Color.atlasHairline,
                    lineWidth: contrast == .increased ? 1.5 : 1
                )
            )
    }
}

/// Section header with optional interactive action button (>= 44 pt hit target).
struct SectionHeading: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.sectionLabel)
                .foregroundStyle(Color.atlasMoss)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.rowSubtitle.weight(.semibold))
                    .foregroundStyle(Color.atlasClay)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            } else if let actionTitle {
                Text(actionTitle)
                    .font(.rowSubtitle.weight(.semibold))
                    .foregroundStyle(Color.atlasClay)
            }
        }
    }
}

/// Settings-inspired rounded icon tile with continuous corners that scales with Dynamic Type.
struct IconTile: View {
    let systemImage: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 32
    var baseSize: CGFloat = 32

    private var resolvedSize: CGFloat {
        min(max(baseSize, scaledSize * (baseSize / 32)), 52)
    }

    init(systemImage: String, color: Color, size: CGFloat = 32) {
        self.systemImage = systemImage
        self.color = color
        self.baseSize = size
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: resolvedSize * 0.24, style: .continuous)
        Image(systemName: systemImage)
            .font(.symbol)
            .foregroundStyle(.white)
            .frame(width: resolvedSize, height: resolvedSize)
            .background(color.gradient, in: shape)
            .accessibilityHidden(true)
    }
}

/// Category pill combining symbol + text so meaning is never conveyed by color alone.
struct CategoryBadge: View {
    let category: PlaceCategory

    var body: some View {
        Label(category.displayName, systemImage: category.systemImage)
            .font(.badge)
            .foregroundStyle(category.tintColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(category.tintColor.opacity(0.14), in: Capsule())
    }
}

/// Accessible 1–5 star rating control with >= 44pt targets and VoiceOver adjustable support.
struct StarRatingControl: View {
    @Binding var rating: Int

    var body: some View {
        AdaptiveStack(spacing: 8) {
            Text("Rating")
                .font(.bodyText)
            Spacer()
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        rating = (rating == star) ? 0 : star
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.symbol)
                            .foregroundStyle(star <= rating ? Color.atlasAmber : .secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(rating == 0 ? "Unrated" : "\(rating) out of 5 stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                rating = min(5, rating + 1)
            case .decrement:
                rating = max(0, rating - 1)
            @unknown default:
                break
            }
        }
    }
}

/// Compact stat tile for History and Offline overview strips.
struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.symbolCompact)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.detailTitle)
                .monospacedDigit()
                .foregroundStyle(Color.atlasInk)
            Text(title)
                .font(.note)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// Loads and displays a downsampled photo attachment thumbnail asynchronously off the main thread.
struct AttachmentThumbnailView: View {
    @EnvironmentObject private var atlas: AtlasViewModel
    let attachment: PlaceAttachment
    var cornerRadius: CGFloat = 12

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.atlasMist)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.symbol)
                            .foregroundStyle(Color.atlasMoss)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: attachment.id) {
            image = await atlas.loadThumbnailImage(for: attachment)
        }
    }
}

/// Shareable plain-text/UTF-8 file wrapper for SwiftUI `ShareLink`.
struct ExportedTextItem: Transferable {
    let filename: String
    let content: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { item in
            Data(item.content.utf8)
        }
        .suggestedFileName { $0.filename }
    }
}

struct ExportedDataItem: Transferable {
    let filename: String
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { item in
            item.data
        }
        .suggestedFileName { $0.filename }
    }
}

/// Formats distances consistently across routes and places.
enum DistanceFormatting {
    static func string(forMeters meters: Double) -> String {
        guard meters.isFinite else { return "0 m" }
        if meters < 1000 {
            return "\(Int(max(0, meters).rounded())) m"
        }
        return String(format: "%.2f km", meters / 1000.0)
    }
}
