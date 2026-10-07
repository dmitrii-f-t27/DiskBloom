import SwiftUI

struct AssistantPanel: View {
    @EnvironmentObject private var assistant: AssistantModel
    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "What can I safely clear?",
        "What takes the most space in my home folder?",
        "Show my biggest caches",
        "Which apps leave the most data behind?"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.separator.opacity(0.6)).frame(height: 1)
            conversation
            Rectangle().fill(Color.separator.opacity(0.6)).frame(height: 1)
            input
        }
        .background(Color.panel)
        .sheet(isPresented: $assistant.showingSettings) {
            AssistantSettingsSheet()
                .environmentObject(assistant)
                .environmentObject(assistant.settings)
        }
        .onAppear { inputFocused = true }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentMint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Assistant")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                let status = assistant.providerStatus
                HStack(spacing: 4) {
                    Circle()
                        .fill(status.ready ? Color.accentMint : CacheVerdict.optional.color)
                        .frame(width: 6, height: 6)
                    Text(status.text)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button { assistant.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(IconButtonStyle())
                .help("New conversation")
            Button { assistant.showingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(IconButtonStyle())
                .help("Choose the model")
            Button { assistant.isPresented = false } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle())
                .help("Close the assistant")
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if assistant.messages.isEmpty {
                        welcome
                    }
                    ForEach(assistant.messages) { message in
                        AssistantMessageView(message: message)
                            .id(message.id)
                    }
                    if assistant.isThinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking…")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.secondaryText)
                            Spacer()
                            Button("Stop") { assistant.stop() }
                                .buttonStyle(SecondaryButtonStyle(compact: true))
                        }
                        .id("thinking")
                    }
                }
                .padding(14)
            }
            .onChange(of: assistant.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(assistant.isThinking ? "thinking" : assistant.messages.last?.id as AnyHashable?, anchor: .bottom) }
            }
            .onChange(of: assistant.isThinking) { _, thinking in
                if thinking { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about your disk. The assistant looks up real sizes and opens the right place in DiskBloom.")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions, id: \.self) { suggestion in
                Button { assistant.send(suggestion) } label: {
                    HStack {
                        Text(suggestion)
                            .font(.system(size: 11, weight: .medium))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.primaryText)
                    .padding(10)
                    .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
            Label("It never deletes anything. It can select items; you review the paths and confirm.", systemImage: "checkmark.shield")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.accentMint)
                .fixedSize(horizontal: false, vertical: true)
            if !assistant.providerStatus.ready {
                Button { assistant.showingSettings = true } label: {
                    Label("Set up the model", systemImage: "gearshape")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask DiskBloom…", text: $assistant.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { assistant.send() }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
            Button { assistant.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(accented: true))
            .disabled(assistant.isThinking || assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(12)
    }
}

private struct AssistantMessageView: View {
    @EnvironmentObject private var assistant: AssistantModel
    let message: AssistantMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color(red: 0.035, green: 0.09, blue: 0.09))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.accentMint, in: RoundedRectangle(cornerRadius: 11))
            }
        case .assistant:
            Text(Self.markdown(message.text))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.primaryText)
                .textSelection(.enabled)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 11))
        case .action:
            Button {
                if let target = message.target { assistant.perform(target) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .bold))
                    Text(message.text)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color.accentMint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.accentMint.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Open again")
        case .error:
            Label {
                Text(message.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(CacheVerdict.quitFirst.color)
            .padding(10)
            .background(CacheVerdict.quitFirst.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var icon: String {
        switch message.target {
        case .section: "rectangle.on.rectangle"
        case .folder: "chart.pie.fill"
        case .reveal: "finder"
        case nil: "bolt.fill"
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

struct AssistantSettingsSheet: View {
    @EnvironmentObject private var assistant: AssistantModel
    @EnvironmentObject private var settings: AssistantSettings
    @Environment(\.dismiss) private var dismiss

    @State private var keyDraft = ""
    @State private var loadedModels: [String] = []
    @State private var isWorking = false
    @State private var feedback: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentMint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Assistant model")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Choose who answers: Apple's model on this Mac, or any OpenAI-compatible API.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
            }
            .padding(20)

            Rectangle().fill(Color.separator).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Source", selection: $settings.provider) {
                        ForEach(AssistantProviderKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch settings.provider {
                    case .apple: appleSection
                    case .api: apiSection
                    }
                }
                .padding(20)
            }

            Rectangle().fill(Color.separator).frame(height: 1)

            HStack {
                if let feedback {
                    Label(feedback.text, systemImage: feedback.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(feedback.ok ? Color.accentMint : CacheVerdict.quitFirst.color)
                        .lineLimit(3)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
    }

    private var appleSection: some View {
        let status = AppleAssistantSupport.status()
        return VStack(alignment: .leading, spacing: 10) {
            Label(status.text, systemImage: status.ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(status.ready ? Color.accentMint : CacheVerdict.optional.color)
            note("Runs entirely on this Mac: free, private, works offline. Needs macOS 26 with Apple Intelligence turned on. It is smaller than cloud models, so answers are simpler.")
            if let languages = AppleAssistantSupport.supportedLanguagesDescription() {
                note("Understands: \(languages). For other languages, use an API.")
            }
        }
    }

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Provider") {
                Picker("Provider", selection: Binding(
                    get: { settings.presetID },
                    set: { id in
                        settings.apply(AssistantEndpointPreset.preset(id: id))
                        keyDraft = ""
                        loadedModels = []
                        feedback = nil
                    }
                )) {
                    ForEach(AssistantEndpointPreset.all) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                }
                .labelsHidden()
            }
            note(settings.preset.note)

            field("API address") {
                TextField("https://…/v1", text: $settings.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }

            field("API key") {
                HStack(spacing: 8) {
                    SecureField(settings.hasAPIKey ? "Saved in Keychain — type to replace" : "Paste the key", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let saved = settings.saveAPIKey(keyDraft)
                        feedback = saved
                            ? (true, keyDraft.isEmpty ? "Key removed from Keychain." : "Key saved in Keychain.")
                            : (false, "Keychain did not accept the key.")
                        keyDraft = ""
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(keyDraft.isEmpty && !settings.hasAPIKey)
                }
            }
            if settings.isLocalEndpoint {
                note("Local server: no key needed, and nothing leaves this Mac.")
            }

            field("Model") {
                HStack(spacing: 8) {
                    TextField("model name", text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    let choices = loadedModels.isEmpty ? settings.preset.suggestedModels : loadedModels
                    if !choices.isEmpty {
                        Menu {
                            ForEach(choices, id: \.self) { name in
                                Button(name) { settings.model = name }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 28)
                        .help(loadedModels.isEmpty ? "Suggested models" : "Models from the provider")
                    }
                    Button("Load list") { loadModels() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .disabled(isWorking)
                }
            }

            HStack(spacing: 10) {
                Button {
                    testConnection()
                } label: {
                    if isWorking { ProgressView().controlSize(.small) } else { Label("Test connection", systemImage: "bolt.horizontal") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isWorking || settings.model.isEmpty)
                Spacer()
            }

            if !settings.isLocalEndpoint {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "network")
                        .foregroundStyle(CacheVerdict.optional.color)
                    Text("With an API, your questions and the names, paths and sizes of the folders the assistant looks at are sent to \(URL(string: settings.normalizedBaseURL)?.host ?? "the provider"). File contents are never sent. The key stays in your Keychain.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .background(CacheVerdict.optional.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func loadModels() {
        isWorking = true
        feedback = nil
        let baseURL = settings.normalizedBaseURL
        let key = settings.apiKey
        Task {
            do {
                let models = try await OpenAICompatibleBackend.availableModels(baseURL: baseURL, apiKey: key)
                loadedModels = models
                feedback = models.isEmpty ? (false, "The provider returned no models; type the name.") : (true, "\(models.count) models loaded. Pick one from the menu.")
            } catch {
                feedback = (false, error.localizedDescription)
            }
            isWorking = false
        }
    }

    private func testConnection() {
        isWorking = true
        feedback = nil
        let baseURL = settings.normalizedBaseURL
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = settings.apiKey
        Task {
            do {
                let reply = try await OpenAICompatibleBackend.testConnection(baseURL: baseURL, model: model, apiKey: key)
                feedback = (true, "Works. \(model) answered: \(reply.prefix(60))")
            } catch {
                feedback = (false, error.localizedDescription)
            }
            isWorking = false
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color.secondaryText)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Color.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}
