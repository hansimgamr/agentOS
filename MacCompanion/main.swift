import AppKit
import LocalAuthentication
import CoreImage.CIFilterBuiltins
import MultipeerConnectivity
import SwiftUI

@main
struct AgentOSCompanionApp: App {
    @AppStorage("companion.appearance") private var appearance = "system"
    @State private var page: String? = "Overview"
    @State private var showingSettings = false

    var body: some Scene {
        Window("agentOS Companion", id: "main") {
            CompanionView(appearance: $appearance, page: $page, showingSettings: $showingSettings)
                .frame(minWidth: 720, minHeight: 520)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 900, height: 760)
        .commands { CompanionSettingsCommands(showingSettings: $showingSettings) }

    }
}

struct CompanionSettingsCommands: Commands {
    @Binding var showingSettings: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "main")
                showingSettings = true
            }.keyboardShortcut(",", modifiers: .command)
        }
    }
}

@MainActor
final class CompanionModel: NSObject, ObservableObject {
    @Published var status: [String: Any] = [:]
    @Published var devices: [[String: Any]] = []
    @Published var qrImage: NSImage?
    @Published var pairingExpiry: Date?
    @Published var secondsRemaining = 0
    @Published var error: String?
    @Published var feedback: String?
    @Published var busy = false
    @Published var revokingDeviceID: String?
    @Published var nearbyStatus = ""
    @Published var nearbyPeerName: String?
    @Published var showingNearbyRequest = false
    @Published var nearbyComparisonCode: String?
    @Published var nearbySecondsRemaining = 0
    private var ticker: Timer?
    private var ticketID: String?
    private var pairingDeviceCount = 0
    private var interactionGeneration = 0
    private var isActive = false
    private var refreshing = false
    private var refreshAgain = false
    private let localPeer = MCPeerID(displayName: "agentOS Mac")
    private var nearbySession: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var invitationHandler: ((Bool, MCSession?) -> Void)?
    private var acceptedPeer: MCPeerID?
    private var handshake: NearbyHandshake?
    private var nearbyDeadline: Date?
    private var nearbyActive = false
    private var nearbyTicketID: String?
    private var nearbyGeneration = 0
    private var nearbyInvitationSent = false

    override init() {
        super.init()
        refresh()
        ticker = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var remaining: Int { secondsRemaining }
    var pairingActive: Bool { qrImage != nil && remaining > 0 }
    var nearbyPairingActive: Bool { nearbyActive }

    func becameActive() {
        isActive = true
        interactionGeneration += 1
        refresh()
    }

    func refresh() {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        let ticketAtStart = ticketID
        Task {
            defer {
                refreshing = false
                if refreshAgain {
                    refreshAgain = false
                    refresh()
                }
            }
            do {
                async let statusResult = CompanionCommand.run(["action": "status"])
                async let deviceResult = CompanionCommand.run(["action": "list_devices"])
                let (newStatus, newDevices) = try await (statusResult, deviceResult)
                let listedDevices = newDevices["devices"] as? [[String: Any]] ?? []
                let pending = newStatus["pending_pairing"] as? [String: Any]
                let pendingID = pending?["ticket_id"] as? String
                if let localTicket = ticketAtStart, localTicket == ticketID, pendingID != localTicket {
                    let paired = pendingID == nil && listedDevices.count > pairingDeviceCount
                    qrImage = nil
                    pairingExpiry = nil
                    ticketID = nil
                    secondsRemaining = 0
                    if paired {
                        feedback = "Invitation accepted. Check that the device shows Connected."
                        if nearbyActive { finishNearby(success: true) }
                    }
                }
                status = newStatus
                devices = listedDevices
                error = nil
            } catch { show(error) }
        }
    }

    func prepareConnection() {
        guard !busy, !pairingActive, !nearbyActive else { return }
        busy = true
        error = nil
        feedback = "Preparing your secure connection…"
        Task {
            defer { busy = false; refresh() }
            do {
                _ = try await CompanionCommand.run(["action": "prepare_connection"])
                feedback = "Connection prepared. Checking services; when both are online, pair your device."
            } catch {
                feedback = nil
                self.error = "Setup couldn’t finish. Make sure Hermes is installed and its model is configured, connect this Mac to your local network, then try Prepare connection again."
            }
        }
    }

    func createPairing() {
        guard !busy, isActive, !nearbyActive else { return }
        busy = true
        let generation = interactionGeneration
        Task {
            defer { busy = false }
            do {
                let result = try await CompanionCommand.run(["action": "create_pairing"])
                guard let ticket = result["ticket_id"] as? String else { throw CompanionError.invalidResponse }
                guard isActive && generation == interactionGeneration else {
                    _ = try? await CompanionCommand.run(["action": "cancel_pairing", "ticket_id": ticket])
                    return
                }
                guard let url = result["qr_url"] as? String,
                      let expiry = result["expires_at"] as? NSNumber,
                      let image = Self.qr(url) else {
                    _ = try? await CompanionCommand.run(["action": "cancel_pairing", "ticket_id": ticket])
                    throw CompanionError.invalidResponse
                }
                qrImage = image
                pairingExpiry = Date(timeIntervalSince1970: expiry.doubleValue)
                ticketID = ticket
                pairingDeviceCount = devices.count
                secondsRemaining = max(0, Int((pairingExpiry ?? .distantPast).timeIntervalSinceNow.rounded(.up)))
                feedback = nil
                error = nil
                refresh()
            } catch { show(error) }
        }
    }

    func cancelPairing() {
        guard qrImage != nil else { return }
        let ticket = ticketID
        qrImage = nil
        pairingExpiry = nil
        ticketID = nil
        secondsRemaining = 0
        feedback = nil
        Task {
            do {
                var request: [String: Any] = ["action": "cancel_pairing"]
                if let ticket { request["ticket_id"] = ticket }
                _ = try await CompanionCommand.run(request)
            }
            catch { show(error) }
            refresh()
        }
    }

    func startNearbyPairing() {
        guard isActive, !busy, !pairingActive, !nearbyActive else { return }
        nearbyActive = true
        nearbyGeneration += 1
        nearbyDeadline = Date().addingTimeInterval(300)
        nearbySecondsRemaining = 300
        nearbyComparisonCode = nil
        nearbyPeerName = nil
        nearbyStatus = "Looking for a nearby iPhone…"
        feedback = nil
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        nearbySession = session
        let service = MCNearbyServiceAdvertiser(peer: localPeer, discoveryInfo: nil, serviceType: "agentos-pair")
        service.delegate = self
        advertiser = service
        service.startAdvertisingPeer()
    }

    func approveNearbyPeer() {
        guard nearbyActive, let handler = invitationHandler, let session = nearbySession else { return }
        invitationHandler = nil
        showingNearbyRequest = false
        nearbyPeerName = nil
        handler(true, session)
        nearbyStatus = "Connecting securely…"
    }

    func declineNearbyPeer() {
        // One request per opt-in window; declining stops discovery to prevent prompt spam.
        cancelNearbyPairing()
    }

    func confirmNearbyCode() {
        guard nearbyActive, !busy, nearbyComparisonCode != nil, nearbyTicketID == nil,
              let code = nearbyComparisonCode, let handshake, let session = nearbySession,
              let peer = session.connectedPeers.first else { return }
        do { try handshake.confirmComparison(code: code) }
        catch { abortNearby("Secure code confirmation failed. Cancel and try again."); return }
        let generation = nearbyGeneration
        busy = true
        nearbyStatus = "Preparing secure invitation…"
        Task {
            defer { busy = false }
            do {
                let result = try await CompanionCommand.run(["action": "create_pairing"])
                guard let ticket = result["ticket_id"] as? String,
                      let url = result["qr_url"] as? String else { throw CompanionError.invalidResponse }
                guard nearbyActive && generation == nearbyGeneration else {
                    _ = try? await CompanionCommand.run(["action": "cancel_pairing", "ticket_id": ticket])
                    return
                }
                let sealed = try handshake.sealInvitation(url)
                nearbyTicketID = ticket
                ticketID = ticket
                try session.send(sealed, toPeers: [peer], with: .reliable)
                nearbyInvitationSent = true
                pairingDeviceCount = devices.count
                nearbyStatus = "Invitation sent securely. Waiting for the iPhone to connect…"
                nearbyComparisonCode = nil
                error = nil
                refresh()
            } catch { abortNearby("Nearby pairing could not be completed.") }
        }
    }

    func cancelNearbyPairing() {
        guard nearbyActive else { return }
        finishNearby(success: false)
    }

    func revoke(_ device: [String: Any]) {
        guard revokingDeviceID == nil, let id = device["id"] as? String else { return }
        revokingDeviceID = id
        Task {
            defer { revokingDeviceID = nil }
            let context = LAContext()
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: "Authenticate to revoke this device’s access to Hermes.") else { return }
            } catch {
                self.error = "Device access was not removed. Authenticate to revoke this pairing."
                return
            }
            do {
                let result = try await CompanionCommand.run(["action": "revoke", "device_id": id])
                guard result["revoked"] as? Bool == true else { throw CompanionError.actionFailed }
                refresh()
            } catch { show(error) }
        }
    }

    func tick() {
        if let pairingExpiry {
            secondsRemaining = max(0, Int(pairingExpiry.timeIntervalSinceNow.rounded(.up)))
            if qrImage != nil && secondsRemaining == 0 { cancelPairing() }
        }
        if let nearbyDeadline {
            nearbySecondsRemaining = max(0, Int(nearbyDeadline.timeIntervalSinceNow.rounded(.up)))
            if nearbySecondsRemaining == 0 { cancelNearbyPairing() }
        }
    }

    func becameInactive() {
        isActive = false
        interactionGeneration += 1
        cancelPairing()

    }

    private func accept(_ peer: MCPeerID, context: Data?, handler: @escaping (Bool, MCSession?) -> Void,
                        from source: MCNearbyServiceAdvertiser) {
        guard nearbyActive, source === advertiser, invitationHandler == nil, acceptedPeer == nil,
              nearbySession?.connectedPeers.isEmpty == true, (context?.count ?? 0) <= 256 else {
            handler(false, nil)
            return
        }
        advertiser?.stopAdvertisingPeer()
        invitationHandler = handler
        acceptedPeer = peer
        let suppliedName = context.flatMap { String(data: $0, encoding: .utf8) } ?? peer.displayName
        let safeName = String(suppliedName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80))
        nearbyPeerName = safeName.isEmpty ? "Nearby iPhone" : safeName
        showingNearbyRequest = true
        nearbyStatus = "Review the device name before accepting."
    }

    private func handleNearbyMessage(_ data: Data, from peer: MCPeerID) {
        guard nearbyActive, let handshake, nearbySession?.connectedPeers.contains(peer) == true else { return }
        do {
            if let reply = try handshake.receive(data) {
                try nearbySession?.send(reply, toPeers: [peer], with: .reliable)
            }
            if let code = handshake.comparisonCode {
                nearbyComparisonCode = code
                nearbyStatus = "Compare this code with the iPhone."
            }
        } catch { abortNearby("Secure handshake failed. Cancel and try again.") }
    }

    private func abortNearby(_ message: String) {
        error = message
        finishNearby(success: false)
    }

    private func stopNearbyTransport() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        acceptedPeer = nil
        nearbySession?.disconnect()
        nearbySession?.delegate = nil
        nearbySession = nil
        handshake = nil
    }

    private func finishNearby(success: Bool) {
        let ticket = success ? nil : nearbyTicketID
        nearbyGeneration += 1
        nearbyActive = false
        nearbyDeadline = nil
        nearbySecondsRemaining = 0
        nearbyComparisonCode = nil
        nearbyPeerName = nil
        showingNearbyRequest = false
        nearbyInvitationSent = false
        nearbyStatus = success ? "Device paired successfully." : "Nearby pairing cancelled."
        invitationHandler?(false, nil)
        invitationHandler = nil
        stopNearbyTransport()
        nearbyTicketID = nil
        if let ticket {
            ticketID = nil
            Task {
                _ = try? await CompanionCommand.run(["action": "cancel_pairing", "ticket_id": ticket])
                refresh()
            }
        } else if success {
            ticketID = nil
        }
    }

    private func show(_ error: Error) {
        // Backend diagnostics can contain private details. Show only a stable generic message.
        self.error = "That action couldn’t finish. Open Overview and check both services. If either needs attention, choose Prepare connection, then try again."
    }

    private static func qr(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension CompanionModel: MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in self.accept(peerID, context: context, handler: invitationHandler, from: advertiser) }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            guard self.advertiser === advertiser else { return }
            self.abortNearby("Nearby discovery is unavailable. Check Local Network access and try again.")
        }
    }

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard self.nearbyActive, session === self.nearbySession, self.acceptedPeer == peerID else { return }
            switch state {
            case .connected:
                guard session.encryptionPreference == .required else {
                    self.abortNearby("Secure nearby transport is unavailable.")
                    return
                }
                self.handshake = NearbyHandshake(role: .mac)
                self.nearbyStatus = "Establishing an encrypted pairing session…"
            case .notConnected:
                if self.nearbyInvitationSent {
                    self.stopNearbyTransport()
                    self.nearbyStatus = "Waiting for the iPhone to finish pairing…"
                } else {
                    self.abortNearby("The iPhone disconnected. You can try nearby pairing again.")
                }
            case .connecting:
                self.nearbyStatus = "Connecting securely…"
            @unknown default:
                self.abortNearby("Nearby pairing could not be completed.")
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard session === self.nearbySession, self.acceptedPeer == peerID else { return }
            self.handleNearbyMessage(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
        Task { @MainActor in if session === self.nearbySession && self.acceptedPeer == peerID { self.abortNearby("Unexpected nearby data received.") } }
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
        Task { @MainActor in if session === self.nearbySession && self.acceptedPeer == peerID { self.abortNearby("Unexpected nearby data received.") } }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        if error != nil { Task { @MainActor in if session === self.nearbySession && self.acceptedPeer == peerID { self.abortNearby("Nearby transfer failed.") } } }
    }
}

enum CompanionError: Error { case unavailable, invalidResponse, actionFailed }

enum CompanionCommand {
    static func run(_ request: [String: Any]) async throws -> [String: Any] {
        try await Task.detached(priority: .userInitiated) {
            guard let script = Bundle.main.resourceURL?.appending(path: "MacRelay/companion.py"),
                  FileManager.default.fileExists(atPath: script.path) else { throw CompanionError.unavailable }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path]
            process.standardInput = Pipe()
            process.standardOutput = Pipe()
            process.standardError = FileHandle.nullDevice
            try process.run()
            let input = process.standardInput as! Pipe
            let output = process.standardOutput as! Pipe
            let data = try JSONSerialization.data(withJSONObject: request)
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.closeFile()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let value = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  value["ok"] as? Bool == true else { throw CompanionError.actionFailed }
            return value
        }.value
    }
}

struct CompanionView: View {
    @Binding var appearance: String
    @Binding var page: String?
    @Binding var showingSettings: Bool
    @StateObject private var model = CompanionModel()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("agentOS.onboarding.v1") private var onboardingComplete = false
    @State private var showingOnboarding = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var selectedDevice: [String: Any]?
    private let inactive = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
    private var statusGood: Bool {
        let backend = model.status["backend"] as? [String: Any]
        let relay = model.status["relay"] as? [String: Any]
        return backend?["available"] as? Bool == true && relay?["available"] as? Bool == true
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            List(selection: $page) {
                Label("Overview", systemImage: "heart.text.square").tag("Overview")
                Label("Paired Devices", systemImage: "iphone.gen3").badge(model.devices.count).tag("Paired Devices")
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch page {
                    case "Paired Devices": devicesCard
                    default:
                        pairingCard
                        connectionCard
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    }
                    if let feedback = model.feedback {
                        Label(feedback, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    }
                }
                .padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .navigationTitle(page ?? "Overview")
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                ToolbarItemGroup {
                    Button { showingSettings.toggle() } label: {
                        Label("Appearance settings", systemImage: appearance == "dark" ? "moon.fill" : appearance == "light" ? "sun.max.fill" : "gearshape")
                    }
                    .help("Appearance settings")
                    .popover(isPresented: $showingSettings, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Appearance", systemImage: "circle.lefthalf.filled").font(.headline)
                            Picker("Appearance", selection: $appearance) {
                                Label("Follow System", systemImage: "desktopcomputer").tag("system")
                                Label("Light", systemImage: "sun.max").tag("light")
                                Label("Dark", systemImage: "moon").tag("dark")
                            }.pickerStyle(.radioGroup).labelsHidden()
                            Divider()
                            Button("Welcome to agentOS", systemImage: "sparkles") {
                                showingSettings = false
                                showingOnboarding = true
                            }
                        }
                        .padding(20).frame(width: 240)
                        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                    }
                    Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh status and devices")
                }
            }
        }
        .onReceive(inactive) { _ in model.becameInactive() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.becameActive() }
        .sheet(isPresented: $showingOnboarding, onDismiss: { onboardingComplete = true }) {
            WelcomeTour { onboardingComplete = true; showingOnboarding = false }
        }
        .onAppear {
            model.becameActive()
            if !onboardingComplete { showingOnboarding = true }
        }
        .onDisappear { model.becameInactive(); model.cancelNearbyPairing() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in model.cancelNearbyPairing() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.tick() }
        .alert("Revoke this device?", isPresented: Binding(get: { selectedDevice != nil }, set: { if !$0 { selectedDevice = nil } })) {
            Button("Cancel", role: .cancel) { selectedDevice = nil }
            Button("Revoke Device", role: .destructive) {
                if let device = selectedDevice { model.revoke(device) }
                selectedDevice = nil
            }
        } message: {
            Text("\(selectedDevice?["name"] as? String ?? "This device") will lose access to Hermes immediately.")
        }
        .alert("Allow nearby pairing?", isPresented: $model.showingNearbyRequest) {
            Button("Allow This Device") { model.approveNearbyPeer() }
            Button("Decline", role: .cancel) { model.declineNearbyPeer() }
        } message: {
            Text("\(model.nearbyPeerName ?? "An iPhone") is requesting to pair. The device name is supplied by the phone and may be misleading; allow only the iPhone you are holding.")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 30)).foregroundStyle(.blue.gradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your connection").font(.title3.weight(.semibold))
                    Text(model.status.isEmpty ? "Checking services…" : statusGood ? "Hermes is ready" : "Connection needs attention")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                serviceIndicator("Hermes", icon: "sparkles", state: model.status["backend"] as? [String: Any])
                serviceIndicator("Secure relay", icon: "network", state: model.status["relay"] as? [String: Any])
            }
            Divider()
            LabeledContent("Relay address") {
                Text((model.status["relay"] as? [String: Any])?["endpoint"] as? String ?? "Checking…")
                    .textSelection(.enabled)
            }.font(.callout)
            if let fp = (model.status["relay"] as? [String: Any])?["fingerprint"] as? String, !fp.isEmpty {
                Text("Relay certificate · SHA-256 fingerprint").font(.caption).foregroundStyle(.secondary)
                Text(fp).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text(model.devices.count == 1 ? "1 paired device" : "\(model.devices.count) paired devices").foregroundStyle(.secondary)
                Spacer()
                Button("Manage devices") { page = "Paired Devices" }
            }
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var pairingCard: some View {
        VStack(spacing: 13) {
            cardTitle("Pair a device", icon: "qrcode")
            if !statusGood && !model.pairingActive && !model.nearbyPairingActive {
                Image(systemName: "desktopcomputer").font(.system(size: 54, weight: .light)).foregroundStyle(.blue)
                Text(model.status.isEmpty ? "Checking your Mac…" : model.status["hermes_installed"] as? Bool == false ? "Install Hermes first" : "Prepare your Mac")
                    .font(.title3.weight(.semibold))
                Text("Hermes must already be installed and configured with a model. agentOS prepares the local API, secure relay, and pairing details for you.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if model.status["hermes_installed"] as? Bool == false {
                    Link("Hermes installation guide", destination: URL(string: "https://github.com/nousresearch/hermes-agent#installation")!)
                } else {
                    Button { model.prepareConnection() } label: {
                        HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.busy ? "Preparing…" : "Prepare connection") }
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.status.isEmpty)
                    Text("One step. No IP address, certificate, or access key to copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.nearbyComparisonCode != nil {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 44)).foregroundStyle(.blue.gradient).frame(height: 94)
                Text("Compare the codes").font(.callout.weight(.semibold))
                Text(model.nearbyComparisonCode ?? "------").font(.system(size: 34, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(.primary)
                Text("Compare these digits on your iPhone. If they differ, cancel and start again.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { model.confirmNearbyCode() } label: {
                    Label("Codes match — Pair", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
                Button("Cancel nearby pairing", role: .cancel) { model.cancelNearbyPairing() }.controlSize(.small)
            } else if model.nearbyPairingActive {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 48, weight: .light)).foregroundStyle(.blue.gradient).frame(height: 96)
                Text(model.nearbyStatus).font(.callout.weight(.medium)).multilineTextAlignment(.center)
                Text("Expires in \(model.nearbySecondsRemaining / 60):\(String(format: "%02d", model.nearbySecondsRemaining % 60))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Cancel nearby pairing", role: .cancel) { model.cancelNearbyPairing() }.controlSize(.small)
            } else if model.pairingActive, let image = model.qrImage {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 160, height: 160)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
                Text("Scan in agentOS or with your iPhone camera").font(.callout.weight(.medium))
                Text("Expires in \(model.remaining / 60):\(String(format: "%02d", model.remaining % 60))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Cancel pairing", role: .cancel) { model.cancelPairing() }.controlSize(.small)
            } else {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 50, weight: .light)).foregroundStyle(.blue.gradient).frame(height: 90)
                Text("Connect your iPhone or iPad").font(.callout.weight(.medium))
                Text("Scan a QR code or pair nearby. Invitations expire after five minutes.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { model.createPairing() } label: {
                        Label(model.busy ? "Creating…" : "Pair device", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy || model.nearbyPairingActive)
                    Button { model.startNearbyPairing() } label: {
                        Label("Pair nearby", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.large).disabled(model.busy || model.pairingActive)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20).background(cardBackground)
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                cardTitle("Paired devices", icon: "iphone")
                Spacer()
                Text("\(model.devices.count)").font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 4).background(Color.blue.opacity(0.12), in: Capsule()).foregroundStyle(.blue)
            }
            if model.devices.isEmpty {
                ContentUnavailableView("No paired devices", systemImage: "iphone.slash", description: Text("Go to Overview to pair an iPhone or iPad. Keep both devices on the same local network."))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                ForEach(model.devices.indices, id: \.self) { index in
                    let device = model.devices[index]
                    HStack(spacing: 13) {
                        Image(systemName: "iphone").font(.system(size: 20)).foregroundStyle(.blue).frame(width: 42, height: 42).background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device["name"] as? String ?? "iPhone").font(.callout.weight(.semibold))
                            Text("Paired \(date(device["created"]))").font(.caption).foregroundStyle(.secondary)
                            Text("Certificate accepted: \(date(device["certificate_accepted_at"]))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let fingerprint = device["certificate_fingerprint"] as? String {
                                DisclosureGroup("Accepted fingerprint") {
                                    Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.font(.caption)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) { selectedDevice = device } label: { Label("Revoke", systemImage: "minus.circle").labelStyle(.titleAndIcon) }
                            .buttonStyle(.bordered).controlSize(.small).help("Revoke this device's access")
                            .disabled(model.revokingDeviceID != nil)
                    }
                    .padding(.vertical, 5)
                    if index < model.devices.count - 1 { Divider().padding(.leading, 55) }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)).overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }.shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.035), radius: 12, y: 4)
    }

    private func cardTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline).labelStyle(.titleAndIcon)
    }

    private func serviceIndicator(_ name: String, icon: String, state: [String: Any]?) -> some View {
        let active = state?["available"] as? Bool == true
        let tint: Color = state == nil ? .secondary : active ? .green : .orange
        return HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 58, height: 58)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.headline)
                Label(state == nil ? "Checking…" : active ? "Online" : "Needs attention",
                      systemImage: state == nil ? "clock" : active ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(tint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func date(_ value: Any?) -> String {
        guard let seconds = value as? NSNumber else { return "Not recorded" }
        return Date(timeIntervalSince1970: seconds.doubleValue).formatted(date: .abbreviated, time: .shortened)
    }
}
