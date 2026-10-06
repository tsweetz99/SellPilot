import SwiftUI
import UIKit
extension Double { var money: String { formatted(.currency(code: "USD").precision(.fractionLength(0...2))) } }
enum PilotTheme {
    static let ink = Color(red: 0.10, green: 0.17, blue: 0.20)
    static let accent = Color(red: 0.04, green: 0.43, blue: 0.34)
    static let background = Color(uiColor: .systemGroupedBackground)
}
struct PrimaryButton: View {
    var title: String; var icon: String = "arrow.right"; var action: () -> Void
    var body: some View { Button(action: action) { HStack { Text(title); Spacer(); Image(systemName: icon) }.font(.headline).padding(18).foregroundStyle(.white).background(PilotTheme.accent, in: RoundedRectangle(cornerRadius: 18)) }.buttonStyle(.plain) }
}
struct PilotCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 14) { content }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22)) }
}
struct PhotoView: View {
    var photo: SellItemPhoto; var height: CGFloat = 180; var original = false
    var body: some View {
        ZStack {
            if let image = displayImage { Image(uiImage: image).resizable().scaledToFit().padding(original || photo.enhancement.style == .original ? 0 : 12) }
            else { Image(systemName: "photo").font(.largeTitle) }
        }.frame(maxWidth: .infinity).frame(height: height)
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
        VStack(alignment: .leading, spacing: 5) { Text(item.title).font(.headline).lineLimit(2); Text(item.selectedMarketplace.rawValue).font(.caption).foregroundStyle(.secondary); Text(item.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
            if item.status == .sold { Text("Sold \((item.soldPrice ?? 0).money) · \(item.soldDate?.formatted(date: .abbreviated, time: .omitted) ?? "")").font(.caption) }
            else { Text(item.askingPrice > 0 ? item.askingPrice.money : "Price to come").font(.subheadline.bold()) }
        }; Spacer(minLength: 0); Text(item.status.rawValue).font(.caption.bold()).padding(7).background(PilotTheme.accent.opacity(0.10), in: Capsule())
    }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18)) }
}
