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
