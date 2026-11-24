import Foundation
#if canImport(AVFoundation) && os(iOS) && !HOST_TESTING
import AVFoundation
#endif

@MainActor
protocol SpokenDirectionsSpeaking: AnyObject {
    func speak(_ announcement: SpokenDirectionsAnnouncementV1)
    func stopSpeaking()
}

/// Turns navigation events into speech while the rider's setting is on.
/// Test Navigation goes through the same engine events, so it speaks too.
@MainActor
final class SpokenDirectionsController {
    private var planner: SpokenDirectionsPlannerV1
    private let speaker: any SpokenDirectionsSpeaking
    private let isEnabled: () -> Bool
    private var isActive = false
    private var preferenceObserver: NSObjectProtocol?

    init(
        speaker: (any SpokenDirectionsSpeaking)? = nil,
        usesMetricSystem: Bool = Locale.current.measurementSystem == .metric,
        isEnabled: @escaping () -> Bool = { SpokenDirectionsPreference.isEnabled() },
        observesPreferenceChanges: Bool = true
    ) {
        self.speaker = speaker ?? Self.systemSpeaker()
        self.isEnabled = isEnabled
        planner = SpokenDirectionsPlannerV1(usesMetricSystem: usesMetricSystem)
        guard observesPreferenceChanges else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferenceChanged() }
        }
    }

    deinit {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
    }

    func handle(_ event: SpokenDirectionsEventV1) {
        guard isEnabled() else {
            deactivate()
            return
        }
        isActive = true
        switch planner.handle(event) {
        case .speak(let announcement):
            speaker.speak(announcement)
        case .silence:
            speaker.stopSpeaking()
        case nil:
            break
        }
    }

    /// Turning the setting off silences speech at once. Turning it on during
    /// a ride announces the next maneuver on the following fix.
    func preferenceChanged() {
        if !isEnabled() { deactivate() }
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        planner.reset()
        speaker.stopSpeaking()
    }

    private static func systemSpeaker() -> any SpokenDirectionsSpeaking {
#if canImport(AVFoundation) && os(iOS) && !HOST_TESTING
        SystemSpokenDirectionsSpeaker()
#else
        SilentSpokenDirectionsSpeaker()
#endif
    }
}

@MainActor
final class SilentSpokenDirectionsSpeaker: SpokenDirectionsSpeaking {
    func speak(_ announcement: SpokenDirectionsAnnouncementV1) {}
    func stopSpeaking() {}
}

#if canImport(AVFoundation) && os(iOS) && !HOST_TESTING
/// iOS speech for navigation prompts. The shared audio session is active
/// only while something is being said: voice-prompt mode lowers other apps'
/// audio and pauses spoken audio such as podcasts, then deactivation lets
/// them return to full volume.
///
/// Speaking while Bicino is in the background needs the `audio` background
/// mode, which only the Debug (Bicino Dev) Info.plist declares. In other
/// builds activation fails in the background and the prompt is skipped; the
/// settings footer tells those riders to keep Bicino open on screen.
@MainActor
final class SystemSpokenDirectionsSpeaker: NSObject, SpokenDirectionsSpeaking, AVSpeechSynthesizerDelegate {
    private struct Queued {
        let utterance: AVSpeechUtterance
        let kind: SpokenDirectionsAnnouncementV1.Kind
    }

    private var synthesizer: AVSpeechSynthesizer?
    /// Holds each queued utterance, so its identifier stays unique until
    /// the synthesizer reports it finished or cancelled.
    private var queued: [ObjectIdentifier: Queued] = [:]
    private var speakingKind: SpokenDirectionsAnnouncementV1.Kind?
    private var sessionActive = false
    private var releaseRetries = 0
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated {
                // A call or Siri took the audio and the system deactivated
                // the session; a prompt is stale once it ends.
                self?.sessionActive = false
                self?.stopSpeaking()
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func speak(_ announcement: SpokenDirectionsAnnouncementV1) {
        let synthesizer = activeSynthesizer()
        if !synthesizer.isSpeaking {
            // Nothing is queued. Forget entries whose callbacks never came,
            // and activate again: iOS can end the session without notice,
            // for example when a Release build moves to the background.
            queued.removeAll()
            speakingKind = nil
            sessionActive = false
        } else if SpokenDirectionsQueuePolicyV1.shouldInterrupt(speaking: speakingKind, with: announcement) {
            queued.removeAll()
            speakingKind = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard activateSession() else { return }
        let utterance = AVSpeechUtterance(string: announcement.text)
        utterance.voice = Self.voice
        queued[ObjectIdentifier(utterance)] = Queued(utterance: utterance, kind: announcement.kind)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        queued.removeAll()
        speakingKind = nil
        if synthesizer?.isSpeaking == true {
            synthesizer?.stopSpeaking(at: .immediate)
        }
        releaseSessionIfIdle()
    }

    /// The app is English: an English voice in the rider's regional variant
    /// when there is one, matching the phrasing and the Apple Maps text.
    private static var voice: AVSpeechSynthesisVoice? {
        let appLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let current = AVSpeechSynthesisVoice.currentLanguageCode()
        let code = current.hasPrefix(appLanguage) ? current : appLanguage
        return AVSpeechSynthesisVoice(language: code) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private func activeSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let created = AVSpeechSynthesizer()
        created.delegate = self
        synthesizer = created
        return created
    }

    private func activateSession() -> Bool {
        releaseRetries = 0
        guard !sessionActive else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true)
            sessionActive = true
            return true
        } catch {
            print("Spoken directions could not start audio: \(error)")
            return false
        }
    }

    private func releaseSessionIfIdle() {
        guard sessionActive, queued.isEmpty, synthesizer?.isSpeaking != true else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        } catch {
            // Speech output can still be draining right after the last
            // callback. Retry briefly so other audio is not left lowered.
            guard releaseRetries < 3 else {
                print("Spoken directions could not release audio: \(error)")
                return
            }
            releaseRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated { self?.releaseSessionIfIdle() }
            }
        }
    }

    private func utteranceStarted(_ id: ObjectIdentifier) {
        if let kind = queued[id]?.kind { speakingKind = kind }
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        queued.removeValue(forKey: id)
        if queued.isEmpty { speakingKind = nil }
        releaseSessionIfIdle()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceStarted(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.utteranceEnded(id) }
    }
}
#endif
