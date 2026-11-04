import SwiftUI
import ZuluStore

/// A person's own picture, or their initials when there is no picture to show.
///
/// The initials are shown *instead of* the picture, never behind it: an avatar with any
/// transparency in it was letting a wheel of colour through from underneath.
struct SenderAvatar: View {
    let name: String
    var userID: Int?
    /// The message's own snapshot of the sender's avatar. Messages keep the URL they
    /// were sent with, so the live user record is preferred where there is one.
    var url: String?
    var size: CGFloat = 36

    @Environment(AppModel.self) private var model
    @State private var loaded: (source: String, image: Image)?

    private var source: String? {
        userID.flatMap { model.users[$0]?.avatarURL } ?? url
    }

    /// A reused row keeps its state, so a picture only counts if it was loaded for this source.
    private var image: Image? {
        guard let source else { return nil }
        if let loaded, loaded.source == source { return loaded.image }
        return DecodedImages.image(at: source)
    }

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.circle)
            } else {
                Avatar(name: name, size: size)
            }
        }
        // The Mac's conversation table reuses a row's view for another sender, and the
        // drawn picture outlived the source check above. A new source is a new view.
        .id(source)
        .task(id: source) { await load() }
    }

    private func load() async {
        guard let source, !source.isEmpty else { return }
        if let cached = DecodedImages.image(at: source) {
            loaded = (source, cached)
            return
        }
        // Gravatar and the realm's own uploads both arrive here; `imageData` decides
        // which of them may see the account's credentials.
        guard let data = await model.imageData(at: source),
              let decoded = Platform.image(from: data)
        else { return }
        DecodedImages.store(decoded, at: source)
        loaded = (source, decoded)
    }
}
