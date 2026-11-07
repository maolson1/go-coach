import AppKit
import Foundation

@MainActor
public final class SoundManager {
    public static let shared = SoundManager()
    public var isMuted: Bool = false

    private init() {}

    public func playStoneClick() {
        guard !isMuted else { return }
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    public func playCapture() {
        guard !isMuted else { return }
        NSSound(named: NSSound.Name("Pop"))?.play()
    }

    public func playCoachIntervention() {
        guard !isMuted else { return }
        NSSound(named: NSSound.Name("Glass"))?.play()
    }
}
