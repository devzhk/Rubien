#if os(macOS)
import AVFoundation
import Speech

/// Asks macOS for microphone and speech-recognition access.
@MainActor
struct SystemDictationAuthorizer: DictationAuthorizing {
    func requestAccess(to permission: DictationPermission) async -> Bool {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
            default: return false
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return true
            case .notDetermined: return await Self.requestSpeechRecognition()
            default: return false
            }
        }
    }

    /// The handler runs on an arbitrary queue, so it is built off the main
    /// actor; the caller resumes on the main actor.
    nonisolated private static func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
#endif
