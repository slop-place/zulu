import SwiftUI
import ZuluMarkup

/// An uploaded file, drawn as a card with its type, name and a download mark. A tap goes
/// through `openURL`, which `attachmentPreviews()` routes to Quick Look.
struct AttachmentRow: View {
    let attachment: MessageAttachment

    @Environment(\.openURL) private var openURL

    private static let maxWidth: CGFloat = 320
    private static let cornerRadius: CGFloat = 10
    private static let iconCornerRadius: CGFloat = 7
    private static let iconSize: CGFloat = 36
    private static let padding: CGFloat = 10
    private static let spacing: CGFloat = 10
    private static let borderWidth: CGFloat = 0.5
    private static let textSpacing: CGFloat = 2
    private static let iconTintOpacity = 0.15
    private static let fillOpacity = 0.5
    private static let downloadSymbol = "arrow.down.circle"

    var body: some View {
        Button {
            guard let url = URL(string: attachment.path, relativeTo: RealmContext.realmURL)?.absoluteURL
            else { return }
            openURL(url)
        } label: {
            HStack(spacing: Self.spacing) {
                Image(systemName: attachment.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .background(.tint.opacity(Self.iconTintOpacity), in: RoundedRectangle(cornerRadius: Self.iconCornerRadius))
                VStack(alignment: .leading, spacing: Self.textSpacing) {
                    Text(attachment.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !attachment.fileExtension.isEmpty {
                        Text(attachment.fileExtension.uppercased())
                            .font(.caption)
                            .foregroundStyle(TextTone.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: Self.downloadSymbol)
                    .font(.title3)
                    .foregroundStyle(TextTone.secondary)
            }
            .padding(Self.padding)
            .background(.quaternary.opacity(Self.fillOpacity), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(.quaternary, lineWidth: Self.borderWidth)
            }
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        #if os(macOS)
        .pointerStyle(.link)
        #endif
        .accessibilityLabel(attachment.name)
        .accessibilityHint("Opens the file")
    }
}

extension AttachmentKind {
    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .archive: "doc.zipper"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.text"
        case .other: "doc"
        }
    }
}
