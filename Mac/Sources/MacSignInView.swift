import SwiftUI
import ZulipAPI

/// Sign-in as a single centred card rather than the iOS grouped form, which on a Mac
/// window would be a page of grey with three controls in it.
struct MacSignInView: View {
    @Environment(AppModel.self) private var model

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var realmURL: URL?
    @State private var settings: ServerSettings?
    @State private var checking = false
    @State private var lookupError: String?
    @FocusState private var focus: Field?

    private enum Field { case address, username, password }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text("Zulu").font(.title.weight(.semibold))
            }

            if let settings, let realmURL {
                connected(settings, realmURL)
            } else {
                addressEntry
            }
        }
        .padding(32)
        .frame(width: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The window opens ready to type into; a sign-in screen that needs a click
        // first is a sign-in screen that is not sure what it is for.
        .task { focus = .address }
        .onChange(of: settings) { _, settings in
            focus = settings?.passwordAuthEnabled == true ? .username : .address
        }
    }

    private var addressEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Zulip server").font(.subheadline.weight(.semibold))
            TextField("chat.example.com", text: $address)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .focused($focus, equals: .address)
                .onSubmit { Task { await lookUp() } }

            if let lookupError {
                Text(lookupError).font(.caption).foregroundStyle(.red)
            } else {
                Text("The address of your Zulip organization.")
                    .font(.caption).foregroundStyle(TextTone.secondary)
            }

            HStack {
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Continue") { Task { await lookUp() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.isEmpty || checking)
            }
        }
    }

    @ViewBuilder
    private func connected(_ settings: ServerSettings, _ realmURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(settings.realm_name ?? "Zulip").font(.headline)
                    Text(realmURL.host() ?? "").font(.caption).foregroundStyle(TextTone.secondary)
                }
                Spacer()
                Button("Change") {
                    self.settings = nil
                    self.realmURL = nil
                }
                .buttonStyle(.link)
            }

            if settings.passwordAuthEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        settings.usernameIsEmail ? "Email" : "Username", text: $username
                    )
                    .textContentType(settings.usernameIsEmail ? .emailAddress : .username)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit { signIn(realmURL) }

                    if let error = model.signInError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }

                    HStack {
                        Spacer()
                        if model.isWorking { ProgressView().controlSize(.small) }
                        Button("Sign in") { signIn(realmURL) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(username.isEmpty || password.isEmpty || model.isWorking)
                    }
                }
            }

            if !settings.externalMethods.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or continue with")
                        .font(.caption).foregroundStyle(TextTone.secondary)
                    ForEach(settings.externalMethods) { method in
                        Button(method.display_name) {
                            Task {
                                await model.signInWithBrowser(realmURL: realmURL, method: method)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func signIn(_ realmURL: URL) {
        Task { await model.signIn(realmURL: realmURL, username: username, password: password) }
    }

    private func lookUp() async {
        checking = true
        lookupError = nil
        defer { checking = false }
        do {
            let (url, found) = try await model.serverSettings(for: address)
            realmURL = url
            settings = found
        } catch {
            lookupError = AppModel.describe(error)
        }
    }
}
