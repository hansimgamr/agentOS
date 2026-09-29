import SwiftUI
import PhotosUI
import UIKit
import VisionKit
import AVFoundation

private enum MainTab: Hashable { case chats, settings }
private enum ChatRoute: Hashable { case newChat, conversation(String) }

struct RootView: View {
    @Environment(ChatStore.self) private var store
    @AppStorage("openSearchRequested") private var openSearchRequested = false
    @AppStorage("agentOS.onboarding.v1") private var onboardingComplete = false
    @State private var showingOnboarding = false
    @State private var showingSearch = false
    @State private var showingScanner = false
    @State private var showingNearbyPairing = false
    @State private var scannedPairingURL: URL?
    @State private var chatToDelete: ChatSession?
    @State private var deletionError: String?
    @State private var chatEditMode: EditMode = .inactive
    @State private var selectedChats: Set<String> = []
    @State private var confirmingBulkDelete = false
    @State private var deletingSelectedChats = false
    @State private var selectedTab: MainTab = .chats
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var chatPath: [ChatRoute] = []
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
        .sheet(isPresented: $showingOnboarding) {
            WelcomeTour(allowsClose: onboardingComplete) {
                onboardingComplete = true
                showingOnboarding = false
            }
            .interactiveDismissDisabled(!onboardingComplete)
            .presentationDragIndicator(onboardingComplete ? .visible : .hidden)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("agentOS.showWelcome"))) { _ in showingOnboarding = true }
        .sheet(isPresented: $showingSearch) {
            AppSearchView(openSettings: {
                showingSearch = false
                selectedTab = .settings
            }) { session in
                if !store.sessions.contains(where: { $0.id == session.id }) { store.sessions.append(session) }
                selectedTab = .chats
                showingSearch = false
                openConversation(session.id)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingScanner, onDismiss: {
            if let url = scannedPairingURL {
                scannedPairingURL = nil
                selectedTab = .settings
                Task { await store.pairFromVerifiedInvitation(url) }
            }
        }) {
            PairingScannerView { url in
                scannedPairingURL = url
                showingScanner = false
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingNearbyPairing, onDismiss: {
            if let url = scannedPairingURL {
                scannedPairingURL = nil
                selectedTab = .settings
                Task { await store.pairFromVerifiedInvitation(url) }
            }
        }) {
            NearbyPairingView(scanned: { url in
                scannedPairingURL = url
                showingNearbyPairing = false
            })
            .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nearbyAgentPairing)) { _ in showingNearbyPairing = true }
        .onReceive(NotificationCenter.default.publisher(for: .scanAgentPairing)) { _ in showingScanner = true }
        .onReceive(NotificationCenter.default.publisher(for: .openAgentSearch)) { _ in showingSearch = true }
        .onChange(of: openSearchRequested, initial: true) { _, requested in
            if requested { showingSearch = true; openSearchRequested = false }
        }
        .alert("Couldn’t delete conversation", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) { Button("OK", role: .cancel) { deletionError = nil } }
        message: { Text(deletionError ?? "") }
        .confirmationDialog("Pair with this Mac?", isPresented: Binding(
            get: { store.pairingCandidate != nil },
            set: { if !$0 { store.cancelPairing() } }
        ), titleVisibility: .visible, presenting: store.pairingCandidate) { candidate in
            Button("Pair with \(candidate.host)") { Task { await store.confirmPairing(candidate) } }
            Button("Cancel", role: .cancel) { store.cancelPairing() }
        } message: { candidate in
            Text("Connect to \(candidate.host)? Continue only if you just scanned the QR code shown by your own agentOS Companion. The app checks its certificate automatically.")
        }
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
            if !onboardingComplete { showingOnboarding = true }
            if !store.apiKey.isEmpty && !store.isConnected { await store.connect() }
        }
    }

    @ViewBuilder private var chats: some View {
        if horizontalSizeClass == .compact {
            NavigationStack(path: $chatPath) {
                conversationList
                    .navigationDestination(for: ChatRoute.self) { route in
                        ChatView(selectedTab: $selectedTab, selectedPhoto: $selectedPhoto)
                            .task(id: route) {
                                if case .conversation(let id) = route,
                                   let session = store.sessions.first(where: { $0.id == id }) {
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
            List(selection: $selectedChats) {
                Section {
                    if !store.isConnected {
                        ScanPairingButton()
                        NearbyPairingButton()
                    }
                    if store.sessions.isEmpty {
                        Button {
                            if store.isConnected { startConversation() }
                            else { selectedTab = .settings }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.isConnected ? "Start a conversation" : "Connect to your Mac")
                                    Text(store.isConnected ? "Chat with Hermes" : "Open agentOS Companion on your Mac")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: store.isConnected ? "bubble.left.and.bubble.right" : "point.3.connected.trianglepath.dotted") }
                        }
                    }
                    ForEach(store.sessions) { session in
                        Group {
                            if chatEditMode == .active {
                                conversationRow(session)
                            } else {
                                Button { if chatEditMode != .active { openConversation(session.id) } } label: { conversationRow(session) }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Opens conversation. Touch and hold to select chats.")
                            }
                        }
                        .tag(session.id)
                        .confirmationDialog("Delete conversation?", isPresented: Binding(
                            get: { chatToDelete?.id == session.id },
                            set: { if !$0 && chatToDelete?.id == session.id { chatToDelete = nil } }
                        ), titleVisibility: .visible, presenting: chatToDelete) { session in
                            Button("Delete", role: .destructive) {
                                Task {
                                    do {
                                        try await store.deleteSession(session.id)
                                        if !store.sessions.contains(where: { $0.id == session.id }) {
                                            chatPath.removeAll { $0 == .conversation(session.id) }
                                            compactColumn = .sidebar
                                        }
                                    } catch { deletionError = error.localizedDescription }
                                }
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: { session in
                            Text("Delete “\(session.title)” and its messages from Hermes? This cannot be undone.")
                        }
                        .disabled(store.deletingSessionIDs.contains(session.id))
                        .simultaneousGesture(LongPressGesture().onEnded { _ in
                            guard !deletingSelectedChats, !store.isSending, store.isConnected else { return }
                            selectedChats.insert(session.id)
                            chatEditMode = .active
                        })
                        .accessibilityAction(named: "Select conversation") {
                            selectedChats.insert(session.id)
                            chatEditMode = .active
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if chatEditMode != .active {
                                Button(role: .destructive) { chatToDelete = session } label: { Label("Delete", systemImage: "trash") }
                                    .tint(.red)
                                    .disabled(store.isSending || store.deletingSessionIDs.contains(session.id))
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, $chatEditMode)
            .disabled(deletingSelectedChats)
            .onChange(of: store.isConnected) { _, connected in
                if !connected { selectedChats.removeAll(); chatEditMode = .inactive }
            }
            .overlay {
                if store.needsPairing {
                    ContentUnavailableView {
                        Label("Pair this device again", systemImage: "laptopcomputer")
                    } description: {
                        Text("Your connection needs a fresh start. Pair with your Mac to continue.")
                    } actions: {
                        NearbyPairingButton()
                        ScanPairingButton()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                }
            }
            .navigationTitle("Chats")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if chatEditMode == .active {
                        Button { confirmingBulkDelete = true } label: {
                            Label("Delete selected", systemImage: "trash")
                        }
                        .tint(.red)
                        .disabled(selectedChats.isEmpty || store.isSending || deletingSelectedChats || !store.isConnected)
                        .confirmationDialog("Delete selected conversations?", isPresented: $confirmingBulkDelete, titleVisibility: .visible) {
                            Button("Delete \(selectedChats.count) conversations", role: .destructive) {
                                let ids = selectedChats
                                deletingSelectedChats = true
                                Task {
                                    do { try await store.deleteSessions(ids) }
                                    catch { deletionError = error.localizedDescription }
                                    selectedChats.formIntersection(Set(store.sessions.map(\.id)))
                                    chatPath.removeAll { route in
                                        if case .conversation(let id) = route { return !store.sessions.contains { $0.id == id } }
                                        return false
                                    }
                                    if selectedChats.isEmpty { chatEditMode = .inactive }
                                    deletingSelectedChats = false
                                }
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("These conversations and their messages will be deleted from Hermes. This cannot be undone.")
                        }
                        Button("Done") { selectedChats.removeAll(); chatEditMode = .inactive }
                            .disabled(deletingSelectedChats)
                    } else {
                        SearchButton()
                        Button { startConversation() } label: { Image(systemName: "square.and.pencil") }
                            .accessibilityLabel("New conversation")
                            .disabled(store.isSending || store.isPairing)
                    }
                }
            }
    }

    private func conversationRow(_ session: ChatSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("🪽 \(session.title)").lineLimit(1)
            HStack(spacing: 6) {
                if let model = ModelName.short(session.modelName) { Text(model).lineLimit(1) }
                if let date = session.lastActive { Text(ChatTimestamp.label(date)) }
            }.font(.caption2).foregroundStyle(.secondary)
            if !session.preview.isEmpty {
                Text(session.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func openConversation(_ id: String) {
        if horizontalSizeClass == .compact {
            chatPath = [.conversation(id)]
        } else if let session = store.sessions.first(where: { $0.id == id }) {
            compactColumn = .detail
            Task { await store.select(session) }
        }
    }

    private func startConversation() {
        guard store.startNewConversation() else { return }
        if horizontalSizeClass == .compact { chatPath = [.newChat] }
        else { compactColumn = .detail }
    }

}

private struct ChatView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var dictationPrefix = ""
    @State private var followsLatest = true
    @State private var showingApproval = false
    @State private var voice = VoiceTranscriber()
    @Binding var selectedTab: MainTab
    @Binding var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            if let error = store.error, !store.needsPairing {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8).background(.red.opacity(0.07))
            }
            if !store.isConnected {
                ContentUnavailableView {
                    Label(store.needsPairing ? "Pair this device again" : "Connect to Hermes", systemImage: "laptopcomputer")
                } description: {
                    Text(store.needsPairing ? "Your connection needs a fresh start. Pair with your Mac to continue." : "Install and configure Hermes on your Mac, then open agentOS Companion. Keep both devices on the same local network and choose QR or nearby pairing.")
                } actions: {
                    VStack(spacing: 12) {
                        ScanPairingButton()
                        NearbyPairingButton()
                        Button("Connection settings") { selectedTab = .settings }
                    }
                    .buttonStyle(.bordered)
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
            ToolbarItem(placement: .topBarTrailing) { SearchButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.connect() } } label: {
                    Image(systemName: store.isConnected ? "checkmark.circle.fill" : "arrow.clockwise.circle")
                        .foregroundStyle(store.isConnected ? .green : .secondary)
                }
                .accessibilityLabel(store.isConnected ? "Connected; refresh conversations" : "Reconnect to Hermes")
            }
        }
        .onChange(of: voice.transcript) { _, text in if !text.isEmpty { store.draft = dictationPrefix + text } }
        .onDisappear { voice.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { voice.stop() }
        }
        .onChange(of: store.pendingApproval?.id, initial: true) { _, id in
            showingApproval = id != nil
        }

    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(DragGesture().onChanged { _ in followsLatest = false })
            .task(id: store.selectedSessionID) {
                followsLatest = true
                await Task.yield()
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .task(id: store.messages) {
                guard followsLatest else { return }
                await Task.yield()
                guard !Task.isCancelled, followsLatest else { return }
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
            .onChange(of: store.error) { _, _ in
                if followsLatest { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: store.isSending) { _, sending in
                if sending { followsLatest = true }
                if followsLatest { proxy.scrollTo("chat-bottom", anchor: .bottom) }
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
                Button { if voice.isRecording { voice.stop() } else {
                    dictationPrefix = store.draft.isEmpty ? "" : store.draft + " "
                    voice.start()
                } } label: { Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic").font(.title3).frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel(voice.isRecording ? "Stop dictation" : "Dictate message")
                Button { voice.stop(); if store.isSending { store.stop() } else { Task { await store.send() } } } label: {
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
                        Text(isUser ? "You" : "Hermes 🪽").fontWeight(.semibold)
                        if !isUser, let model = ModelName.short(message.modelName) { Text(model) }
                        if let date = message.timestamp { Text(ChatTimestamp.label(date)) }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isUser ? "You" : "Hermes 🪽").fontWeight(.semibold)
                        if !isUser, let model = ModelName.short(message.modelName) { Text(model) }
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var protectionTask: Task<Void, Never>?
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var rotating = false
    @State private var confirmingDisconnect = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("faceIDEnabled") private var faceIDEnabled = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Help") {
                    Button("Welcome to agentOS", systemImage: "sparkles") {
                        NotificationCenter.default.post(name: Notification.Name("agentOS.showWelcome"), object: nil)
                    }
                }
                Section("Connection") {
                    HStack(spacing: 12) {
                        if checking {
                            ProgressView().accessibilityLabel("Connecting")
                        } else {
                            Image(systemName: store.isConnected ? "checkmark.circle.fill" : store.apiKey.isEmpty ? "circle" : "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(store.isConnected ? Color.green : store.apiKey.isEmpty ? Color.secondary : Color.red)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(checking ? "Connecting…" : store.isConnected ? "Connected" : "Not connected")
                                .font(.headline)
                            if !store.status.isEmpty && store.status != "Not connected" {
                                Text(store.status).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    #if targetEnvironment(simulator)
                    TextField("https://your-mac.example:8643", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("API server key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    #else
                    if !store.apiKey.isEmpty {
                        LabeledContent("Hermes server", value: store.endpoint)
                        if let profile = KeychainStore.readProfile() {
                            LabeledContent("Certificate accepted", value: profile.certificateAcceptedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not recorded")
                            DisclosureGroup("Certificate fingerprint") {
                                Text(profile.fingerprint).font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            if let deviceID = profile.deviceID { LabeledContent("This iPhone", value: deviceID) }
                        }
                        Text("This iPhone has its own access. The Mac's Hermes key stays on the Mac.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button { Task { rotating = true; await store.rotateDeviceKey(); rotating = false } } label: {
                            HStack { if rotating { ProgressView() }; Text("Rotate this iPhone's access") }
                        }.disabled(rotating)
                        Text("An access key is a secret digital password that lets this iPhone connect to Hermes on your Mac. The app stores and sends it securely—you don’t need to remember or type it. Access renews automatically after 30 days when you next connect. Use this button to replace your key early if you think it was exposed. You stay paired; the old key expires after 10 minutes. Other devices are not affected.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Disconnect this iPhone", role: .destructive) { confirmingDisconnect = true }
                            .disabled(store.isSending || store.isPairing || store.isRemovingPairing)
                            .confirmationDialog("Disconnect this iPhone?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                                Button("Disconnect", role: .destructive) { Task { await store.disconnectWithAuthentication() } }
                                Button("Cancel", role: .cancel) { }
                            } message: {
                                Text("Remove this iPhone's saved Hermes connection. Pair again with a QR code to reconnect.")
                            }
                    } else {
                        Text("Hermes must already be installed and configured on your Mac. Open agentOS Companion and prepare the connection, then scan its QR code or pair nearby. No address or access key to copy.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = store.error, !store.needsPairing { Text(error).font(.footnote).foregroundStyle(.red) }
                    #endif
                    if !store.isConnected {
                        ScanPairingButton()
                        NearbyPairingButton()
                    }
                    Button { Task { await saveAndConnect() } } label: {
                        Label(connectionButtonTitle, systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(checking || endpoint.isEmpty || !canConnect)
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("Follow System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section {
                    Toggle("Use \(DeviceAuthentication.name)", isOn: Binding(
                        get: { faceIDEnabled },
                        set: { enabled in
                            guard !store.isChangingAppProtection else { return }
                            store.appProtectionError = nil
                            if enabled { faceIDEnabled = true }
                            else {
                                protectionTask = Task { await store.disableAppProtectionWithAuthentication() }
                            }
                        }
                    ))
                    .disabled(store.isChangingAppProtection)
                    if let error = store.appProtectionError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(DeviceAuthentication.name)
                } footer: {
                    Text("Require \(DeviceAuthentication.name) to open agentOS. Authenticate to turn protection off.")
                }

            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SearchButton() } }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { endpoint = store.endpoint; apiKey = store.apiKey }
            .onDisappear { protectionTask?.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { protectionTask?.cancel() }
            }

        }
    }

    private var connectionButtonTitle: String {
        if checking { return "Connecting…" }
        #if targetEnvironment(simulator)
        return "Save and connect"
        #else
        return store.isConnected ? "Refresh connection" : "Reconnect"
        #endif
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


extension Notification.Name {
    static let nearbyAgentPairing = Notification.Name("nearbyAgentPairing")
    static let scanAgentPairing = Notification.Name("scanAgentPairing")
    static let openAgentSearch = Notification.Name("openAgentSearch")
}

private struct SearchButton: View {
    var body: some View {
        Button("Search agentOS", systemImage: "magnifyingglass") {
            NotificationCenter.default.post(name: .openAgentSearch, object: nil)
        }
    }
}

private struct AppSearchView: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var voice = VoiceTranscriber()
    @State private var queryPrefix = ""
    @State private var query = ""
    @State private var results: [ChatSession] = []
    @State private var searching = false
    @State private var error: String?
    let openSettings: () -> Void
    let open: (ChatSession) -> Void

    private var matchesSettings: Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !term.isEmpty && "settings appearance theme light dark system connection pairing access".localizedStandardContains(term)
    }

    var body: some View {
        NavigationStack {
            List {
                if voice.isStarting || voice.isRecording {
                    Label(voice.isStarting ? "Preparing microphone…" : "Listening… Tap the microphone to stop.", systemImage: "waveform")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let voiceError = voice.error {
                    Label(voiceError, systemImage: "mic.slash").font(.footnote).foregroundStyle(.red)
                }
                if matchesSettings {
                    Button(action: openSettings) { Label("Settings · Appearance and Connection", systemImage: "gearshape") }
                }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Search agentOS", systemImage: "magnifyingglass",
                        description: Text("Find conversations by title or message text. Type a query or tap the microphone to search by voice."))
                } else if searching {
                    HStack { ProgressView(); Text("Searching conversations…") }
                } else if let error {
                    ContentUnavailableView("Search unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results) { session in
                        Button { open(session) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("🪽 \(session.title)").font(.headline)
                                Text(session.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                VoiceSearchField(text: $query, recording: voice.isRecording || voice.isStarting) {
                    if voice.isRecording || voice.isStarting { voice.stop() }
                    else {
                        queryPrefix = query.isEmpty ? "" : query + " "
                        voice.start()
                    }
                }
                .frame(height: 44)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close search", systemImage: "xmark") { voice.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { voice.stop(); dismiss() } }
            }
            .onChange(of: voice.transcript) { _, text in
                if !text.isEmpty { query = queryPrefix + text }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { voice.stop() }
            }
            .onDisappear { voice.stop() }
            .task(id: query) {
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                results = []; error = nil; searching = !term.isEmpty
                guard !term.isEmpty else { return }
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    let matches = try await store.searchChats(term)
                    try Task.checkCancellation()
                    results = matches; searching = false
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription; searching = false }
                }
            }
        }
    }
}

// Use Apple's search text field with a persistent dictation accessory.
private struct VoiceSearchField: UIViewRepresentable {
    @Binding var text: String
    let recording: Bool
    let toggleDictation: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField()
        field.delegate = context.coordinator
        field.placeholder = "Chats and messages"
        field.accessibilityLabel = "Search chats and messages"
        field.returnKeyType = .search
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        let microphone = UIButton(type: .system)
        microphone.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        microphone.addTarget(context.coordinator, action: #selector(Coordinator.toggleVoice), for: .touchUpInside)
        field.rightView = microphone
        field.rightViewMode = .always
        field.clearButtonMode = .never
        return field
    }

    func updateUIView(_ field: UISearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        if let microphone = field.rightView as? UIButton {
            microphone.setImage(UIImage(systemName: recording ? "stop.circle.fill" : "mic"), for: .normal)
            microphone.accessibilityLabel = recording ? "Stop search dictation" : "Dictate search"
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: VoiceSearchField
        init(_ parent: VoiceSearchField) { self.parent = parent }
        @objc func textChanged(_ field: UITextField) { parent.text = field.text ?? "" }
        @objc func toggleVoice() { parent.toggleDictation() }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}

private struct ScanPairingButton: View {
    var body: some View {
        Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
            NotificationCenter.default.post(name: .scanAgentPairing, object: nil)
        }
    }
}

private struct PairingScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorized = false
    @State private var unavailable: String?
    let scanned: (URL) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let unavailable {
                    ContentUnavailableView {
                        Label("Camera unavailable", systemImage: "camera.fill")
                    } description: {
                        Text(unavailable)
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } else if authorized && scenePhase == .active {
                    PairingCamera(scanned: scanned, failed: { unavailable = $0 })
                        .overlay(alignment: .bottom) {
                            Text("Point at the pairing QR code in agentOS Companion on your Mac.")
                                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                                .padding()
                        }
                } else { ProgressView("Preparing camera…") }
            }
            .navigationTitle("Scan Pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Close scanner", systemImage: "xmark") { dismiss() }
            } }
            .task {
                let permission = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled else { return }
                guard permission else {
                    unavailable = "Allow camera access in Settings, or scan the Mac's QR code with the iPhone Camera app."
                    return
                }
                guard DataScannerViewController.isSupported && DataScannerViewController.isAvailable else {
                    unavailable = "Scanning is unavailable on this device. You can also scan the Mac's QR code with the Camera app."
                    return
                }
                authorized = true
            }
        }
    }
}

private struct PairingCamera: UIViewControllerRepresentable {
    let scanned: (URL) -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.finished else { return }
        do { try scanner.startScanning() }
        catch { Task { @MainActor in failed("Camera scanning could not start. Close this sheet and try again, or use the Camera app.") } }
    }
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true
        scanner.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: PairingCamera
        var finished = false
        init(_ parent: PairingCamera) { self.parent = parent }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for case .barcode(let code) in addedItems {
                guard let payload = code.payloadStringValue, let url = URL(string: payload),
                      url.scheme?.lowercased() == "hermespocket", url.host?.lowercased() == "pair" else { continue }
                finished = true
                scanner.stopScanning()
                parent.scanned(url)
                return
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            scanner.stopScanning()
            parent.failed("Camera scanning is unavailable. Close this sheet and try again, or use the Camera app.")
        }
    }
}

private struct NearbyPairingButton: View {
    var body: some View {
        Button("Pair Nearby Mac", systemImage: "laptopcomputer") {
            NotificationCenter.default.post(name: .nearbyAgentPairing, object: nil)
        }
    }
}
