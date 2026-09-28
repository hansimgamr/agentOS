import SwiftUI
import PhotosUI
import UIKit

private enum MainTab: Hashable { case chats, settings }

struct RootView: View {
    @Environment(ChatStore.self) private var store
    @State private var chatToDelete: ChatSession?
    @State private var deletionError: String?
    @State private var selectedTab: MainTab = .chats
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var chatPath: [String] = []
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        TabView(selection: $selectedTab) {
            chats
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(MainTab.chats)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(MainTab.settings)
        }
        .confirmationDialog("Delete conversation?", isPresented: Binding(
            get: { chatToDelete != nil }, set: { if !$0 { chatToDelete = nil } }
        ), titleVisibility: .visible, presenting: chatToDelete) { session in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await store.deleteSession(session.id)
                        if !store.sessions.contains(where: { $0.id == session.id }) {
                            chatPath.removeAll { $0 == session.id }
                            compactColumn = .sidebar
                        }
                    } catch { deletionError = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { session in
            Text("Delete “\(session.title)” and its messages from Hermes? This cannot be undone.")
        }
        .alert("Couldn’t delete conversation", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) { Button("OK", role: .cancel) { deletionError = nil } }
        message: { Text(deletionError ?? "") }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.82) {
                    store.pendingImage = PendingImage(data: jpeg, mimeType: "image/jpeg")
                }
                selectedPhoto = nil
            }
        }
        .task {
            if !store.apiKey.isEmpty { await store.connect() }
        }
    }

    @ViewBuilder private var chats: some View {
        if horizontalSizeClass == .compact {
            NavigationStack(path: $chatPath) {
                conversationList
                    .navigationDestination(for: String.self) { id in
                        ChatView(selectedTab: $selectedTab, selectedPhoto: $selectedPhoto)
                            .task(id: id) {
                                if let session = store.sessions.first(where: { $0.id == id }) {
                                    await store.select(session)
                                }
                            }
                    }
            }
            .toolbar(chatPath.isEmpty ? .visible : .hidden, for: .tabBar)
        } else {
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                conversationList
            } detail: {
                ChatView(selectedTab: $selectedTab, selectedPhoto: $selectedPhoto)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private var conversationList: some View {
            List {
                Section {
                    if store.sessions.isEmpty {
                        Button {
                            if store.isConnected { Task { await startConversation() } }
                            else { selectedTab = .settings }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.isConnected ? "Start a conversation" : "Connect to your Mac")
                                    Text(store.isConnected ? "Chat with Hermes" : "Pair your device in Settings")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: store.isConnected ? "bubble.left.and.bubble.right" : "point.3.connected.trianglepath.dotted") }
                        }
                    }
                    ForEach(store.sessions) { session in
                        Button {
                            openConversation(session.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title).lineLimit(1)
                                if let date = session.lastActive {
                                    Text(ChatTimestamp.label(date))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if !session.preview.isEmpty { Text(session.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens conversation")
                        .disabled(store.deletingSessionIDs.contains(session.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { chatToDelete = session } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(store.isSending || store.deletingSessionIDs.contains(session.id))
                        }
                    }
                } header: {
                    HStack {
                        Text("Conversations")
                        Spacer()
                        Button { Task { await startConversation() } } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("New conversation")
                    }
                }
            }
            .navigationTitle("Chats")
    }

    private func openConversation(_ id: String) {
        if horizontalSizeClass == .compact {
            chatPath = [id]
        } else if let session = store.sessions.first(where: { $0.id == id }) {
            compactColumn = .detail
            Task { await store.select(session) }
        }
    }

    private func startConversation() async {
        await store.createSession()
        if store.error == nil, let id = store.selectedSessionID {
            openConversation(id)
        }
    }
}

private struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @State private var showingApproval = false
    @State private var voice = VoiceTranscriber()
    @Binding var selectedTab: MainTab
    @Binding var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8).background(.red.opacity(0.07))
            }
            if !store.isConnected {
                ContentUnavailableView {
                    Label("Connect to Hermes", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(store.status + "\nOpen Settings to pair with your Mac.")
                } actions: {
                    Button("Connection settings") { selectedTab = .settings }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedSessionID == nil {
                ContentUnavailableView("Your next idea starts here", systemImage: "sparkles", description: Text("Start a conversation with your Hermes agent."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                messages
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(store.selectedSession?.title ?? "agentOS")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.isConnected {
                composerBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.connect() } } label: {
                    Image(systemName: store.isConnected ? "checkmark.circle.fill" : "arrow.clockwise.circle")
                        .foregroundStyle(store.isConnected ? .green : .secondary)
                }
                .accessibilityLabel(store.isConnected ? "Connected; refresh conversations" : "Reconnect to Hermes")
            }
        }
        .onChange(of: voice.transcript) { _, text in if !text.isEmpty { store.draft = text } }
        .onDisappear { voice.stop() }
        .onChange(of: store.pendingApproval?.id, initial: true) { _, id in
            showingApproval = id != nil
        }
        .confirmationDialog("Hermes needs your approval", isPresented: $showingApproval,
                            titleVisibility: .visible, presenting: store.pendingApproval) { approval in
            if approval.choices.contains("once") {
                Button("Allow once") { Task { await store.respondToApproval("once") } }
            }
            if approval.choices.contains("deny") {
                Button("Deny", role: .destructive) { Task { await store.respondToApproval("deny") } }
            }
            Button("Cancel", role: .cancel) { }
        } message: { approval in
            Text(approval.summary)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.messages.isEmpty {
                        ContentUnavailableView("What can Hermes help with?", systemImage: "bubble.left.and.bubble.right", description: Text("Ask a question, attach a photo, or dictate a message."))
                            .padding(.top, 70)
                    }
                    ForEach(store.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if let activity = store.toolActivity {
                        HStack(spacing: 8) { ProgressView(); Text("Using \(activity)…").font(.footnote).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.pendingApproval != nil {
                        Button("Review Hermes request", systemImage: "hand.raised") {
                            showingApproval = true
                        }
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.messages.count) { _, _ in
                if let id = store.messages.last?.id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var composerBar: some View {
        if #available(iOS 26.0, *) {
            composer.padding(8)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else {
            composer.padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let image = store.pendingImage, let preview = UIImage(data: image.data) {
                HStack {
                    Image(uiImage: preview).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("Image ready to send").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { store.pendingImage = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove image")
                }.padding(.horizontal, 8)
            }
            if voice.isRecording {
                HStack { Image(systemName: "waveform").foregroundStyle(.red); Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript).lineLimit(2); Spacer(); Button("Done") { voice.stop() } }
                    .font(.footnote).padding(.horizontal, 8)
            } else if let error = voice.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "photo").font(.title3).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Attach a photo")
                TextField("Message Hermes…", text: Binding(get: { store.draft }, set: { store.draft = $0 }), axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                    .accessibilityLabel("Message Hermes")
                    .onSubmit { Task { await store.send() } }
                Button { if voice.isRecording { voice.stop() } else { voice.start() } } label: { Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic").font(.title3).frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate message")
                Button { if store.isSending { store.stop() } else { Task { await store.send() } } } label: {
                    Image(systemName: store.isSending ? "stop.circle.fill" : "arrow.up.circle.fill").font(.title).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!store.isSending && store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.pendingImage == nil)
                .accessibilityLabel(store.isSending ? "Stop response" : "Send message")
            }
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(isUser ? "You" : "Hermes").fontWeight(.semibold)
                        if let date = message.timestamp { Text(ChatTimestamp.label(date)) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isUser ? "You" : "Hermes").fontWeight(.semibold)
                        if let date = message.timestamp { Text(ChatTimestamp.label(date)) }
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                MessageBody(text: message.content)
                if message.isStreaming && message.content.isEmpty { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }
}

private struct MessageBody: View {
    let text: String
    var body: some View {
        let segments = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index.isMultiple(of: 2) {
                    if !segment.isEmpty { Text(markdown(segment)).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    let code = segment.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                    Text(code.isEmpty ? segment : code)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            }
        }
    }
    private func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string)) ?? AttributedString(string)
    }
}

private struct SettingsView: View {
    @Environment(ChatStore.self) private var store
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var rotating = false
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("Follow System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section("Hermes API") {
                    TextField("https://your-mac.example:8642", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    #if targetEnvironment(simulator)
                    SecureField("API server key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    #else
                    Text(KeychainStore.read() == nil ? "Scan the pairing QR code shown on your Mac with iPhone Camera. agentOS will open and pair automatically." : "This iPhone has its own revocable access. The Mac's Hermes key stays on the Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if KeychainStore.read() != nil {
                        Button { Task { rotating = true; await store.rotateDeviceKey(); rotating = false } } label: {
                            HStack { if rotating { ProgressView() }; Text("Rotate this iPhone's access") }
                        }.disabled(rotating)
                    }
                    #endif
                }
                Section {
                    Button { Task { await saveAndConnect() } } label: {
                        HStack { if checking { ProgressView() }; Text("Save and connect") }
                            .frame(maxWidth: .infinity)
                    }.disabled(checking || endpoint.isEmpty || !canConnect)
                    if !store.status.isEmpty { Text(store.status).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { endpoint = store.endpoint; apiKey = store.apiKey }
        }
    }

    private var canConnect: Bool {
        #if targetEnvironment(simulator)
        !apiKey.isEmpty
        #else
        !store.apiKey.isEmpty
        #endif
    }

    private func saveAndConnect() async {
        checking = true
        #if targetEnvironment(simulator)
        store.saveSettings(endpoint: endpoint, apiKey: apiKey)
        #else
        store.saveSettings(endpoint: endpoint, apiKey: store.apiKey)
        #endif
        await store.connect()
        checking = false
    }
}
