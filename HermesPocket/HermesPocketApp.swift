import SwiftUI
import LocalAuthentication
import AppIntents

@main
struct HermesPocketApp: App {
    @State private var store = ChatStore()
    @AppStorage("appearance") private var appearance = "system"

    init() { AgentShortcuts.updateAppShortcutParameters() }

    var body: some Scene {
        WindowGroup {
            ProtectedRoot()
                .environment(store)
                .tint(.indigo)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

private struct ProtectedRoot: View {
    @Environment(ChatStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var authenticationRunning = false
    @State private var pendingPairing: URL?
    @State private var unlockError: String?

    var body: some View {
        Group {
            if unlocked {
                RootView()
                    .opacity(scenePhase == .active ? 1 : 0)
                    .allowsHitTesting(scenePhase == .active)
                    .accessibilityHidden(scenePhase != .active)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 48)).foregroundStyle(.indigo)
                    Text("agentOS is locked").font(.title2.bold())
                    Text("Unlock with Face ID, Touch ID or your device passcode.").foregroundStyle(.secondary)
                    if let unlockError { Text(unlockError).font(.footnote).foregroundStyle(.red) }
                    Button("Unlock") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(authenticationRunning)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
        }
        .task { await unlock() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { unlocked = false }
            else { Task { await unlock() } }
        }
        .onOpenURL { url in
            pendingPairing = url
            if unlocked { Task { await finishPairing() } }
            else { Task { await unlock() } }
        }
    }

    private func unlock() async {
        guard scenePhase == .active, !unlocked, !authenticationRunning else { return }
        authenticationRunning = true
        defer { authenticationRunning = false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            unlockError = "Set a device passcode to protect agentOS."
            return
        }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                            localizedReason: "Unlock your Hermes conversations")
            if success {
                unlocked = true
                unlockError = nil
                await finishPairing()
            }
        } catch { unlockError = "Authentication was cancelled. Tap Unlock to try again." }
    }

    private func finishPairing() async {
        guard let pendingPairing, unlocked else { return }
        self.pendingPairing = nil
        await store.pair(from: pendingPairing)
    }
}


struct OpenAgentSearch: AppIntent {
    static var title: LocalizedStringResource = "Search agentOS"
    static var description = IntentDescription("Open private conversation search in agentOS.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "openSearchRequested")
        return .result()
    }
}

struct AgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenAgentSearch(),
                    phrases: ["Search in \(.applicationName)", "Open search in \(.applicationName)"],
                    shortTitle: "Search agentOS", systemImageName: "magnifyingglass")
    }
}
