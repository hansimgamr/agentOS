# Getting started

agentOS is a native chat interface for an existing Hermes agent, with a Mac companion that prepares a local connection and manages paired devices.

## Prerequisites

Install and configure Hermes on your Mac with a working model/provider. The companion does not install Hermes or provide model access. Keep the Mac and iPhone or iPad on the same reachable local network.

The iOS app requires iOS 17 or newer; the companion requires macOS 14 or newer. The downloadable Mac installer targets Apple silicon. The companion helper requires a working `/usr/bin/python3` from Apple developer tools on supported setups.

## Install and connect

1. Download the companion from GitHub Releases, or build it using the README instructions. The current installer is a development build without Developer ID signing or notarization.
2. Open the companion and complete its welcome tour.
3. Choose **Prepare connection** if offered. Hermes and Secure relay should show Online.
4. Install the iOS app through Xcode and complete its welcome tour.
5. Pair using the Mac's **Scan QR code** or **Scan nearby** action. See [pairing](PAIRING.md).
6. Start a conversation and send a message.

Allow Local Network access when prompted. Camera permission is used for QR scanning; microphone and Speech permissions are used for dictation.

## Everyday use

Send text or images, dictate into an editable draft, and search conversations by text or voice. Review agent approval requests before allowing actions. Settings offers Follow System, Light, Dark, and device-appropriate app protection. Disabling protection requires system authentication.

The Mac companion can be closed after pairing because the relay runs independently. The overview's paired-device checkmark means a device record exists; the separate service indicators show the last connection health check.

## Troubleshooting

- **Not connected:** open the companion, check both services, and confirm network reachability and Local Network permission.
- **Pair this device again:** access may have been revoked. Generate a new invitation and pair again.
- **Interrupted response:** refresh the conversation before deciding whether to resend. Automatic retries could duplicate agent actions.
- **Mac changed networks:** prepare the connection again and pair with the updated endpoint.
- **Existing installation under another identifier:** fresh pairing is required. Stop its previous relay launch agent before preparing a replacement service.
