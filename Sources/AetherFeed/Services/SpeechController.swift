import AVFoundation
import Observation

/// Reads text aloud via speech synthesis. Deliberately sets no explicit
/// voice on the utterance: macOS then uses the system-wide default voice
/// (System Settings → Accessibility → Spoken Content), e.g. a Siri voice.
///
/// Multiple UI spots can offer read-aloud; each passes a stable `id` so the
/// active one can render a stop button. Starting a new id replaces the
/// current speech.
@MainActor
@Observable
final class SpeechController {
    static let shared = SpeechController()

    /// The id currently being spoken, nil when idle.
    private(set) var activeID: String?

    private let synthesizer = AVSpeechSynthesizer()
    /// The synthesizer's delegate property is weak — keep a strong reference.
    private var delegate: SpeechDelegate?
    /// Identifies the current utterance: stop-and-replace cancels the old
    /// utterance asynchronously, and that late callback must not clear the
    /// state of the replacement.
    private var currentUtterance: ObjectIdentifier?

    private init() {
        let delegate = SpeechDelegate { [weak self] finished in
            guard let self, self.currentUtterance == finished else { return }
            self.activeID = nil
            self.currentUtterance = nil
        }
        self.delegate = delegate
        synthesizer.delegate = delegate
    }

    func toggle(id: String, text: String) {
        if activeID == id {
            stop()
        } else {
            speak(text, id: id)
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        activeID = nil
        currentUtterance = nil
    }

    private func speak(_ text: String, id: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        currentUtterance = ObjectIdentifier(utterance)
        activeID = id
        synthesizer.speak(utterance)
    }
}

/// Separate NSObject delegate: delegate callbacks may arrive off the main
/// thread, so they hop to the MainActor before touching the controller.
private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let onFinish: @MainActor @Sendable (ObjectIdentifier) -> Void

    init(onFinish: @escaping @MainActor @Sendable (ObjectIdentifier) -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor in onFinish(finished) }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor in onFinish(finished) }
    }
}
