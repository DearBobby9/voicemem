import AVFoundation
import os

private let logger = Logger(subsystem: "com.voicemem.app", category: "Permissions")

/// Microphone permission management.
enum PermissionManager {
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var isMicrophoneGranted: Bool {
        microphoneStatus == .authorized
    }

    static func requestMicrophoneAccess() async -> Bool {
        let status = microphoneStatus
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            logger.info("[Permissions] Microphone access \(granted ? "granted" : "denied")")
            return granted
        case .denied, .restricted:
            logger.warning("[Permissions] Microphone access denied/restricted")
            return false
        @unknown default:
            return false
        }
    }
}
