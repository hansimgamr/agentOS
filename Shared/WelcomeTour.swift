import SwiftUI

/// A replayable tour. Permissions are requested only by the feature that needs them.
struct WelcomeTour: View {
    let finish: () -> Void
    @State private var page = 0

    private struct Slide {
        let symbol: String
        let title: String
        let message: String
        let detail: String
    }

    private var slides: [Slide] {
        #if os(macOS)
        [
            Slide(symbol: "sparkles", title: "Your Mac. Your agent.", message: "Hermes must already be installed and configured on this Mac. agentOS Companion connects your iPhone or iPad to it.", detail: "If setup is needed, choose Prepare connection on Overview. The companion handles the API, secure relay, and pairing details. It never installs Hermes or chooses your model."),
            Slide(symbol: "heart.text.square", title: "Everything at a glance", message: "Overview shows Hermes health, the relay address, and the certificate fingerprint that identifies this Mac.", detail: "Green means the latest check passed. Use Refresh to check again. Keep your phone and Mac on the same local network."),
            Slide(symbol: "iphone.gen3.radiowaves.left.and.right", title: "Pair in a moment", message: "On Overview, choose Pair device for a QR code, or Pair nearby to discover your Mac from the phone.", detail: "QR invitations last five minutes and work once. For nearby pairing, compare the six-digit codes. On your phone, review and trust the Mac’s certificate."),
            Slide(symbol: "checkmark.shield", title: "A private connection", message: "Your phone connects over encrypted HTTPS and checks this Mac’s certificate. The Mac’s Hermes key stays here.", detail: "Each phone gets separate access. Hermes may send your chats and images to its configured model provider. Certificate acceptance dates appear after new pairings."),
            Slide(symbol: "person.badge.key", title: "You control access", message: "Open Paired Devices to review or revoke a phone. Removal requires Touch ID or your Mac password.", detail: "Revoke lost devices here. Access keys renew automatically. Use the toolbar appearance popover to follow the system or choose Light or Dark.")
        ]
        #else
        [
            Slide(symbol: "sparkles", title: "Meet agentOS", message: "Chat with Hermes on your Mac using text, images, code, and voice dictation.", detail: "Hermes must already be installed and configured on your Mac. Open agentOS Companion there to prepare the connection before pairing."),
            Slide(symbol: "qrcode.viewfinder", title: "Pair with your Mac", message: "Keep both devices on the same local network. Open the Mac companion and choose Pair device or Pair nearby.", detail: "Scan the QR code in agentOS or Camera. For nearby pairing, compare the six-digit codes. Review the certificate fingerprint before choosing Trust."),
            Slide(symbol: "lock.shield", title: "Know what’s protected", message: "Your connection to the Mac is encrypted and checked against its trusted certificate. Your device’s access key stays in Keychain.", detail: "Hermes may send chats and images to its configured model provider. This isn’t end-to-end encryption against that provider. Face ID or your passcode protects app access by default."),
            Slide(symbol: "bubble.left.and.bubble.right", title: "Make the conversation yours", message: "Start a chat, add a photo, or tap the microphone to dictate. Review your words before sending.", detail: "Search by typing or dictating. Touch and hold a thread to select chats for deletion. Deleting conversations also removes them from Hermes and cannot be undone."),
            Slide(symbol: "person.badge.key", title: "Stay in control", message: "Settings includes appearance, the Face ID lock, certificate details, and this tour.", detail: "Access renews automatically after 30 days when you connect. Disconnect requires Face ID or your passcode; revoke a lost phone from the Mac. A green check reflects the last connection check—tap it to refresh.")
        ]
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("agentOS").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Button("Skip", action: finish)
            }.padding(24)
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: slides[page].symbol)
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.tint)
                        .frame(width: 128, height: 128)
                        .background(.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 32))
                        .accessibilityHidden(true)
                    Text(slides[page].title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(slides[page].message).font(.title3).multilineTextAlignment(.center)
                    Text(slides[page].detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 480).padding(.horizontal, 28).padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            VStack(spacing: 18) {
                HStack(spacing: 8) {
                    ForEach(slides.indices, id: \.self) { index in
                        Circle().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 7, height: 7)
                    }
                }.accessibilityElement(children: .ignore).accessibilityLabel("Step \(page + 1) of \(slides.count)")
                HStack {
                    Button("Back") { page -= 1 }.disabled(page == 0)
                    Spacer()
                    Button(page == slides.count - 1 ? "Get started" : "Next") {
                        if page == slides.count - 1 { finish() } else { page += 1 }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }.padding(24)
        }
        #if os(macOS)
        .frame(width: 560, height: 620)
        #endif
    }
}
