import LocalAuthentication

/// Query the OS, not a device-model list. This does not display an authentication prompt.
enum DeviceAuthentication {
    static var name: String {
        let context = LAContext()
        // biometryType is populated only after evaluating biometric capability.
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return name(for: context.biometryType)
    }

    static func name(for type: LABiometryType) -> String {
        switch type {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default:
            #if os(macOS)
            return "Password"
            #else
            return "Passcode"
            #endif
        }
    }
}
