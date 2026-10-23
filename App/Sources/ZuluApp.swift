import SwiftUI

@main
struct ZuluApp: App {
    @State private var model = AppModel()
    @UIApplicationDelegateAdaptor private var push: PushNotifications
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(push.settings)
                .task {
                    push.attach(model: model)
                    await model.bootstrap()
                }
                .task(id: model.phase) {
                    if model.phase == .signedIn { await push.enable() }
                }
                .onChange(of: model.destination) { Task { await push.clearDelivered() } }
                .onChange(of: scenePhase) {
                    guard scenePhase == .active else { return }
                    Task {
                        await push.clearDelivered()
                        await model.wakeSync()
                    }
                }
        }

        WindowGroup("Conversation", id: ConversationWindow.id, for: ConversationSource.self) { $source in
            ConversationWindow(source: source)
                .environment(model)
                .environment(push.settings)
                // Restored on its own at launch, this window may be the first to ask.
                .task {
                    push.attach(model: model)
                    await model.bootstrap()
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .signedOut:
            SignInView()
        case .signedIn:
            ShellView().attachmentPreviews()
        }
    }
}
