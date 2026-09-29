import AppKit
import CoreImage.CIFilterBuiltins
import MultipeerConnectivity
import SwiftUI

@main
struct AgentOSCompanionApp: App {
    @AppStorage("companion.appearance") private var appearance = "system"

    var body: some Scene {
        Window("agentOS Companion", id: "main") {
            CompanionView(appearance: $appearance)
                .frame(minWidth: 540, minHeight: 620)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .windowResizability(.contentSize)
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
        guard let id = device["id"] as? String else { return }
        Task {
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
        self.error = "Could not complete that action. Check that Hermes and the relay are available, then try again."
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
    @StateObject private var model = CompanionModel()
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedDevice: [String: Any]?
    private let inactive = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
    private var statusGood: Bool {
        let backend = model.status["backend"] as? [String: Any]
        let relay = model.status["relay"] as? [String: Any]
        return backend?["available"] as? Bool == true && relay?["available"] as? Bool == true
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            connectionCard
                            pairingCard
                        }
                        VStack(spacing: 18) {
                            connectionCard
                            pairingCard
                        }
                    }
                    devicesCard
                    if let error = model.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).padding(.horizontal, 4) }
                    if let feedback = model.feedback { Label(feedback, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout).padding(.horizontal, 4) }
                }
                .padding(28)
                .frame(maxWidth: 960)
                .frame(maxWidth: .infinity)
            }
        }
        .onReceive(inactive) { _ in model.becameInactive() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.becameActive() }
        .onAppear { model.becameActive() }
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

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 38, weight: .medium))
                .symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                .frame(width: 58, height: 58).background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 3) {
                Text("agentOS Companion").font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Connect and manage your iPhone devices").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Appearance", selection: $appearance) {
                Text("Follow System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.menu)
            .help("Choose the app appearance")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)).frame(width: 38, height: 38) }
                .buttonStyle(.bordered).help("Refresh status and devices")
        }
        .padding(.bottom, 3)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            cardTitle("Connection", icon: "point.3.connected.trianglepath.dotted")
            serviceRow("Hermes", detail: (model.status["backend"] as? [String: Any])?["detail"] as? String ?? "Local API", active: (model.status["backend"] as? [String: Any])?["available"] as? Bool == true)
            Divider()
            serviceRow("Secure relay", detail: (model.status["relay"] as? [String: Any])?["endpoint"] as? String ?? "Checking relay", active: (model.status["relay"] as? [String: Any])?["available"] as? Bool == true)
            if let fp = (model.status["relay"] as? [String: Any])?["fingerprint"] as? String, !fp.isEmpty {
                Text("Certificate fingerprint").font(.caption).foregroundStyle(.secondary)
                Text(fp).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 7) {
                Circle().fill(statusGood ? .green : .orange).frame(width: 8, height: 8)
                Text(statusGood ? "Ready to pair" : "Setup needs attention").font(.caption.weight(.medium)).foregroundStyle(statusGood ? .green : .orange)
            }.padding(.top, 2)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(cardBackground)
    }

    private var pairingCard: some View {
        VStack(spacing: 13) {
            cardTitle("Pair a device", icon: "qrcode")
            if model.nearbyComparisonCode != nil {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 44)).foregroundStyle(.blue.gradient).frame(height: 94)
                Text("Compare the codes").font(.callout.weight(.semibold))
                Text(model.nearbyComparisonCode ?? "------").font(.system(size: 34, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(.primary)
                Text("Proceed only if the iPhone shows the same six digits.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
                Text("Scan with your iPhone camera").font(.callout.weight(.medium))
                Text("Expires in \(model.remaining / 60):\(String(format: "%02d", model.remaining % 60))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Cancel pairing", role: .cancel) { model.cancelPairing() }.controlSize(.small)
            } else {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 50, weight: .light)).foregroundStyle(.blue.gradient).frame(height: 165)
                Text("Create a temporary pairing code").font(.callout.weight(.medium))
                Text("The QR code is valid for five minutes.").font(.caption).foregroundStyle(.secondary)
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
        .frame(maxWidth: .infinity, minHeight: 278)
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
                ContentUnavailableView("No paired devices", systemImage: "iphone.slash", description: Text("Pair an iPhone to securely connect it to Hermes."))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            } else {
                ForEach(model.devices.indices, id: \.self) { index in
                    let device = model.devices[index]
                    HStack(spacing: 13) {
                        Image(systemName: "iphone").font(.system(size: 20)).foregroundStyle(.blue).frame(width: 42, height: 42).background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device["name"] as? String ?? "iPhone").font(.callout.weight(.semibold))
                            Text("Added \(date(device["created"])) · \(String((device["id"] as? String ?? "").suffix(6)))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { selectedDevice = device } label: { Label("Revoke", systemImage: "minus.circle").labelStyle(.titleAndIcon) }
                            .buttonStyle(.bordered).controlSize(.small).help("Revoke this device's access")
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

    private func serviceRow(_ name: String, detail: String, active: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(active ? .green : .orange).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Text(active ? "Online" : "Offline").font(.caption.weight(.medium)).foregroundStyle(active ? .green : .orange)
        }
    }

    private func date(_ value: Any?) -> String {
        guard let seconds = value as? NSNumber else { return "recently" }
        return Date(timeIntervalSince1970: seconds.doubleValue).formatted(date: .abbreviated, time: .omitted)
    }
}
