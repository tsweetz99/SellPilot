import SwiftUI
import UIKit
extension Double { var money: String { formatted(.currency(code: "USD").precision(.fractionLength(0...2))) } }
enum PilotTheme {
    static let ink = Color(red: 0.10, green: 0.17, blue: 0.20)
    /// Brand green. Slightly deeper in light mode so green text on tinted backgrounds clears 4.5:1, and a light mint in dark mode.
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.36, green: 0.80, blue: 0.67, alpha: 1) : UIColor(red: 0.03, green: 0.36, blue: 0.29, alpha: 1) })
    /// Text and icons on top of a solid accent fill.
    static let onAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.03, green: 0.14, blue: 0.11, alpha: 1) : .white })
    static let background = Color(uiColor: .systemGroupedBackground)
    /// Secondary text. iOS's own grey is a little too light on the grouped backgrounds (about 4:1), so this is darker in
    /// light mode and lighter in dark mode, both above the 4.5:1 that WCAG asks for.
    static let muted = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.74, alpha: 1) : UIColor(red: 0.27, green: 0.33, blue: 0.35, alpha: 1) })
}
struct PrimaryButton: View {
    var title: String; var icon: String = "arrow.right"; var action: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        // The icon is decoration. At the largest text sizes it is dropped so the title keeps the full width.
        Button(action: action) { HStack { Text(title); if !textSize.isAccessibilitySize { Spacer(); Image(systemName: icon).accessibilityHidden(true) } }.frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(PilotPrimaryButtonStyle())
    }
}
/// A custom style so a disabled button stays readable. SwiftUI fades the label of a plain disabled button, which drops its contrast.
struct PilotPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).padding(18)
            .foregroundStyle(isEnabled ? PilotTheme.onAccent : PilotTheme.muted)
            .background(isEnabled ? PilotTheme.accent : Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
/// A row that becomes a column at the largest text sizes, where side-by-side buttons and labels would clip or wrap mid-word.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var textSize
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content
    var body: some View {
        if textSize.isAccessibilitySize { VStack(alignment: .leading, spacing: spacing) { content } }
        else { HStack(spacing: spacing) { content } }
    }
}
struct PilotCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 14) { content }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22)) }
}
struct PhotoView: View {
    var photo: SellItemPhoto; var height: CGFloat = 180; var original = false
    /// What VoiceOver says for this photo.
    var label = "Photo of the item"
    var body: some View {
        ZStack {
            if let image = displayImage { Image(uiImage: image).resizable().scaledToFit().padding(original || photo.enhancement.style == .original ? 0 : 12) }
            else { Image(systemName: "photo").font(.largeTitle) }
        }.frame(maxWidth: .infinity).frame(height: height)
            .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityAddTraits(.isImage)
            .background(background, in: RoundedRectangle(cornerRadius: 16)).clipped()
    }
    /// Downsampled to the displayed size and cached, so lists never decode full-size photos.
    private var displayImage: UIImage? {
        if !original, let data = photo.enhancement.previewData, let image = UIImage(data: data) { return image }
        return PhotoStorage.shared.thumbnail(id: photo.id, maxPixel: Int(height * 3))
    }
    private var background: Color {
        guard !original else { return Color(uiColor: .tertiarySystemFill) }
        switch photo.enhancement.style { case .original: return Color(uiColor: .tertiarySystemFill); case .clean: return .white; case .studio: return Color(red: 0.91, green: 0.89, blue: 0.85); case .lifestyle: return Color(red: 0.83, green: 0.91, blue: 0.85) }
    }
}
struct ItemCard: View {
    var item: SellItem
    var body: some View { HStack(spacing: 14) {
        if let photo = item.orderedPhotos.first { PhotoView(photo: photo, height: 80).frame(width: 80) } else { Image(systemName: "camera").frame(width: 80, height: 80).background(.quaternary, in: RoundedRectangle(cornerRadius: 12)) }
        VStack(alignment: .leading, spacing: 5) { Text(item.title).font(.headline).lineLimit(2); Text(item.selectedMarketplace.rawValue).font(.caption).foregroundStyle(PilotTheme.muted); Text(item.createdAt, style: .date).font(.caption2).foregroundStyle(PilotTheme.muted)
            if item.status == .sold { Text("Sold \((item.soldPrice ?? 0).money) · \(item.soldDate?.formatted(date: .abbreviated, time: .omitted) ?? "")").font(.caption) }
            else { Text(item.askingPrice > 0 ? item.askingPrice.money : "Price to come").font(.subheadline.bold()) }
        }; Spacer(minLength: 0); Text(item.status.rawValue).font(.caption.bold()).padding(7).background(PilotTheme.accent.opacity(0.10), in: Capsule())
    }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18)) }
}
