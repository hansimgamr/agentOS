import SwiftUI
import MultipeerConnectivity
import UIKit

struct NearbyPairingView: View {
    let scanned: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pairing = NearbyPairingController()

    var body: some View {
        NavigationStack {
            Group {
                if let error = pairing.error {
                    ContentUnavailableView {
                        Label("Nearby pairing failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { pairing.start() }.buttonStyle(.borderedProminent)
                    }
                } else if let url = pairing.receivedURL {
                    invitation(url, host: pairing.receivedHost ?? "Hermes")
                } else if let code = pairing.comparisonCode {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Compare this code on your Mac, then approve pairing there.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                            .accessibilityLabel("Comparison code \(code)")
                    }
                    .padding(28)
                } else if let selected = pairing.selectedPeer {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(pairing.status).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text(selected.displayName).font(.headline)
                    }
                    .padding(28)
                } else {
                    List {
                        Section {
                            Text(pairing.status).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Section("Nearby Macs") {
                            if pairing.peers.isEmpty {
                                Text("Open agentOS Companion on your Mac and choose Pair nearby.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(pairing.peers.enumerated()), id: \.offset) { _, peer in
                                Button {
                                    pairing.connect(to: peer)
                                } label: {
                                    Label(peer.displayName, systemImage: "desktopcomputer")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pair nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pairing.stop(); dismiss() }
                }
            }
        }
        .onAppear { pairing.start() }
        .onDisappear { pairing.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { pairing.pause() }
        }
    }

    private func invitation(_ url: URL, host: String) -> some View {
        VStack(spacing: 14) {
            Label("Mac approved pairing", systemImage: "checkmark.shield.fill")
                .font(.headline).foregroundStyle(.green)
            Text("\(host) is ready to pair.")
                .foregroundStyle(.secondary)
            if let fingerprint = pairing.fingerprint {
                Text("Certificate fingerprint").font(.caption).foregroundStyle(.secondary)
                Text(fingerprint).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .multilineTextAlignment(.center)
            }
            Text("Continue to review the server and confirm its certificate before this iPhone trusts it.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Continue") {
                pairing.stop()
                scanned(url)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
        .padding(24)
    }
}

private final class NearbyPairingController: NSObject, ObservableObject,
                                             MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var selectedPeer: MCPeerID?
    @Published private(set) var comparisonCode: String?
    @Published private(set) var receivedURL: URL?
    @Published private(set) var receivedHost: String?
    @Published private(set) var fingerprint: String?
    @Published private(set) var status = "Searching for Hermes on your local network…"
    @Published private(set) var error: String?

    private let serviceType = "agentos-pair"
    private var localPeer: MCPeerID?
    private var browser: MCNearbyServiceBrowser?
    private var session: MCSession?
    private var handshake: NearbyHandshake?
    private var timeout: Timer?
    private var active = false
    private var generation = 0

    func start() {
        stop()
        generation += 1
        let startedGeneration = generation
        active = true
        peers = []
        selectedPeer = nil
        comparisonCode = nil
        receivedURL = nil
        receivedHost = nil
        fingerprint = nil
        error = nil
        status = "Searching for Hermes on your local network…"
        let peer = MCPeerID(displayName: UIDevice.current.name)
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: serviceType)
        browser.delegate = self
        localPeer = peer
        self.session = session
        self.browser = browser
        browser.startBrowsingForPeers()
        timeout = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == startedGeneration else { return }
                self.fail("Nearby pairing timed out. Keep agentOS Companion open and try again.")
            }
        }
    }

    func stop() {
        generation += 1
        active = false
        timeout?.invalidate()
        timeout = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        session?.disconnect()
        session?.delegate = nil
        browser = nil
        session = nil
        handshake = nil
    }

    func pause() {
        guard active else { return }
        fail("Nearby pairing paused when agentOS went to the background. Tap Try again to restart.")
    }

    func connect(to peer: MCPeerID) {
        guard active, selectedPeer == nil, let browser, let session else { return }
        selectedPeer = peer
        status = "Waiting for approval on your Mac…"
        let context = Data((localPeer?.displayName ?? "iPhone").utf8)
        browser.invitePeer(peer, to: session, withContext: context, timeout: 30)
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.browser === browser, self.selectedPeer == nil,
                  !self.peers.contains(where: { $0 == peerID }) else { return }
            self.peers.append(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.peers.removeAll { $0 == peerID }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.fail("Could not discover nearby Macs: \(error.localizedDescription)")
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.session === session, self.selectedPeer == peerID else { return }
            switch state {
            case .connected:
                self.status = "Securing this pairing…"
                do {
                    let handshake = NearbyHandshake(role: .phone)
                    self.handshake = handshake
                    try self.send(handshake.initialMessage(), to: peerID)
                } catch { self.fail("Could not start secure pairing: \(error.localizedDescription)") }
            case .connecting:
                self.status = "Waiting for approval on your Mac…"
            case .notConnected:
                if self.receivedURL == nil && self.error == nil {
                    self.fail("The Mac declined or ended the nearby session.")
                }
            @unknown default:
                self.fail("This Mac uses an unsupported nearby pairing protocol.")
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.session === session else { return }
            guard self.selectedPeer == peerID else {
                self.fail("An unexpected peer sent data during nearby pairing.")
                return
            }
            guard data.count <= 4096, let handshake = self.handshake else {
                self.fail("The Mac sent an oversized or out-of-sequence pairing message.")
                return
            }
            do {
                if let reply = try handshake.receive(data) { try self.send(reply, to: peerID) }
                if let code = handshake.comparisonCode {
                    self.comparisonCode = code
                    self.status = "Compare on your Mac, then approve pairing there."
                }
                if let invitation = handshake.receivedInvitation {
                    guard let url = URL(string: invitation),
                          let parsed = PairingQR.parse(url),
                          URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "v" && $0.value == "2" }) == true else {
                        self.fail("The Mac sent an unsupported pairing invitation.")
                        return
                    }
                    self.receivedURL = url
                    self.receivedHost = parsed.host
                    self.fingerprint = parsed.fingerprint
                    self.status = "Mac approved this pairing."
                }
            } catch {
                self.fail("Secure pairing could not be verified: \(error.localizedDescription)")
            }
        }
    }

    private func send(_ data: Data, to peer: MCPeerID) throws {
        guard data.count <= 4096, let session else { throw NearbyHandshake.Failure.invalidMessage }
        try session.send(data, toPeers: [peer], with: .reliable)
    }

    private func fail(_ message: String) {
        guard active else { return }
        error = message
        status = "Nearby pairing stopped."
        stop()
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.session === session, self.selectedPeer == peerID else { return }
            self.fail("The Mac sent an unsupported stream. Cancel and restart nearby pairing.")
        }
    }
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.session === session, self.selectedPeer == peerID else { return }
            self.fail("The Mac sent an unsupported file transfer. Cancel and restart nearby pairing.")
        }
    }
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.session === session, self.selectedPeer == peerID else { return }
            self.fail("The Mac sent an unsupported file transfer.")
        }
    }
    func session(_ session: MCSession, didReceive certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(active && self.session === session && selectedPeer == peerID)
    }
}
