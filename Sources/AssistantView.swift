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
    @State private var loadedModels: [AssistantModelInfo] = []
    @State private var modelListSource = ""
    @State private var modelListError: String?
    @State private var isLoadingModels = false
    @State private var modelSearch = ""
    @State private var showAllModels = false
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
        .frame(width: 600, height: 720)
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
                        modelListError = nil
                        modelSearch = ""
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
                        loadModels()
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
                    Button {
                        loadModels()
                    } label: {
                        if isLoadingModels {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(isLoadingModels)
                    .help("Load every model this provider offers")
                }
            }
            if !loadedModels.isEmpty, !loadedModels.contains(where: { $0.id == settings.model }), !settings.model.isEmpty {
                Label("This provider does not list “\(settings.model)”. Pick a model below.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(CacheVerdict.quitFirst.color)
            }
            modelBrowser

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

    /// The searchable list of every model the provider offers.
    @ViewBuilder
    private var modelBrowser: some View {
        let chatModels = loadedModels.filter(\.isChatModel)
        let pool = showAllModels ? loadedModels : chatModels
        let query = modelSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = pool
            .filter { query.isEmpty || $0.id.lowercased().contains(query) }
            .sorted {
                if $0.isRecommended != $1.isRecommended { return $0.isRecommended }
                return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
            }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.secondaryText)
                    TextField("Search models", text: $modelSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 7))
                Toggle("Show all", isOn: $showAllModels)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .help("Also show embedding, safety and other models that cannot chat")
            }
            Group {
                if isLoadingModels && loadedModels.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading the model list…")
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                } else if let modelListError, loadedModels.isEmpty {
                    VStack(spacing: 6) {
                        Text(modelListError)
                            .multilineTextAlignment(.center)
                        if !settings.hasAPIKey, !settings.isLocalEndpoint {
                            Text("Save the API key first; this provider shows its list only with a key.")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .padding(.horizontal, 12)
                } else if loadedModels.isEmpty {
                    Text("No list yet. Click Reload.")
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { info in
                                modelRow(info)
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: 230)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.secondaryText)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 1))
            if !loadedModels.isEmpty {
                Text("\(loadedModels.count) models from \(URL(string: modelListSource)?.host ?? "the provider") · \(chatModels.count) can chat · ★ \(loadedModels.filter(\.isRecommended).count) handle the assistant's tools" + (filtered.count != pool.count ? " · \(filtered.count) match" : ""))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .task(id: settings.normalizedBaseURL + "|\(settings.keyRevision)") {
            if modelListSource != settings.normalizedBaseURL || loadedModels.isEmpty {
                loadModels()
            }
        }
    }

    private func modelRow(_ info: AssistantModelInfo) -> some View {
        let isSelected = info.id == settings.model
        return Button {
            settings.model = info.id
            feedback = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentMint : Color.secondaryText.opacity(0.5))
                Text(info.id)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(info.isChatModel ? Color.primaryText : Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if info.isRecommended {
                    Text("★ tools")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentMint)
                } else if !info.isChatModel {
                    Text("not for chat")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondaryText)
                } else if info.declaresTools == false {
                    Text("no tools")
                        .font(.system(size: 9))
                        .foregroundStyle(CacheVerdict.optional.color)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentMint.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadModels() {
        let baseURL = settings.normalizedBaseURL
        guard URL(string: baseURL)?.host != nil else {
            modelListError = "Enter the API address first."
            return
        }
        isLoadingModels = true
        modelListError = nil
        let key = settings.apiKey
        Task {
            do {
                let models = try await OpenAICompatibleBackend.availableModels(baseURL: baseURL, apiKey: key)
                guard baseURL == settings.normalizedBaseURL else { return }
                loadedModels = models
                modelListSource = baseURL
                if models.isEmpty { modelListError = "The provider returned an empty list; type the model name." }
            } catch {
                guard baseURL == settings.normalizedBaseURL else { return }
                loadedModels = []
                modelListSource = baseURL
                modelListError = error.localizedDescription
            }
            isLoadingModels = false
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
                if !loadedModels.isEmpty, !loadedModels.contains(where: { $0.id == model }) {
                    feedback = (false, "\(URL(string: baseURL)?.host ?? "The provider") has no model “\(model)”. Pick one from the list.")
                } else {
                    feedback = (false, error.localizedDescription)
                }
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
