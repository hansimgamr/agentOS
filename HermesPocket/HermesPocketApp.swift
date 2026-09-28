import SwiftUI
import LocalAuthentication

@main
struct HermesPocketApp: App {
    @State private var store = ChatStore()
    @AppStorage("appearance") private var appearance = "system"

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
            if unlocked && scenePhase == .active {
                RootView()
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
            if phase != .active { unlocked = false }
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
