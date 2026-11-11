import SwiftUI

extension View {
    /// For a row listing a conversation it has nothing current to say about: asks for the
    /// conversation's newest message while the row is on screen. `nil` asks for nothing.
    func requestsNewestMessage(of conversation: ConversationSource?) -> some View {
        modifier(NewestMessageRequest(conversation: conversation))
    }
}

private struct NewestMessageRequest: ViewModifier {
    let conversation: ConversationSource?
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.task(id: conversation) {
            guard let conversation else { return }
            await model.loadNewestMessage(of: conversation)
        }
    }
}
