import AVFoundation
import OSLog

/// The sound language (docs/design/sound-language). Rising leaves you,
/// falling arrives, low stops. Loudness differs only by `volume`: the files
/// all peak at the same level.
enum OperatorSound: Equatable {
    /// Which of the four notes a finished write plays.
    enum AppNote: String { case calendar, gmail, maps, drive }

    case send
    case did(AppNote)
    case done
    case needsYou
    case committed
    case leftIt
    case unsure
    case incoming

    var fileName: String {
        switch self {
        case .send: "1-send"
        case let .did(note): "2-did-\(note.rawValue)"
        case .done: "3-done"
        case .needsYou: "4-needs-you"
        case .committed: "5-committed"
        case .leftIt: "6-left-it"
        case .unsure: "7-unsure"
        case .incoming: "8-incoming"
        }
    }

    var volume: Float {
        switch self {
        case .needsYou: 1
        case .done, .committed: 0.7
        case .send, .leftIt: 0.6
        case .incoming, .unsure: 0.5
        case .did: 0.45
        }
    }

    /// The sound for a tool call that just finished, or nil: reads stay quiet,
    /// only something that changed the world is heard.
    static func forFinishedStep(named name: String) -> OperatorSound? {
        let lowered = name.lowercased()
        let verb = lowered.split(whereSeparator: { $0 == "." || $0 == "_" }).last.map(String.init) ?? lowered
        guard Self.writeVerbs.contains(verb) else { return nil }
        if lowered.contains("calendar") || lowered.contains("reminder") { return .did(.calendar) }
        if lowered.contains("map") || lowered.contains("location") { return .did(.maps) }
        if ["mail", "sms", "message", "whatsapp", "slack", "discord"].contains(where: lowered.contains) { return .did(.gmail) }
        return .did(.drive)
    }

    private static let writeVerbs: Set<String> = [
        "write", "send", "create", "add", "update", "delete", "remove", "reply", "complete", "play", "pause", "set",
    ]

    /// Sounds for steps that are done now and were not before.
    static func forNewlyFinished(before: [ChatActivityStep], after: [ChatActivityStep]) -> [OperatorSound] {
        let alreadyDone = Set(before.filter { $0.state == .done }.map(\.id))
        return after
            .filter { $0.state == .done && !alreadyDone.contains($0.id) }
            .compactMap { Self.forFinishedStep(named: $0.name) }
    }
}

@MainActor
protocol OperatorSoundPlaying: AnyObject {
    func play(_ sound: OperatorSound)
}

/// Plays the bundled files. Follows the ring/silent switch and never
/// interrupts the person's own audio.
@MainActor
final class OperatorSoundPlayer: OperatorSoundPlaying {
    private var players: [String: AVAudioPlayer] = [:]
    private let logger = Logger(subsystem: "app.operator.ios", category: "sounds")
    private var isSessionReady = false

    func play(_ sound: OperatorSound) {
        if !self.isSessionReady {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
            self.isSessionReady = true
        }
        guard let player = self.player(for: sound) else { return }
        player.volume = sound.volume
        player.currentTime = 0
        player.play()
        self.logger.info("[sounds] played \(sound.fileName, privacy: .public)")
    }

    private func player(for sound: OperatorSound) -> AVAudioPlayer? {
        if let cached = self.players[sound.fileName] { return cached }
        guard let url = Bundle.main.url(forResource: sound.fileName, withExtension: "wav"),
              let player = try? AVAudioPlayer(contentsOf: url)
        else {
            self.logger.error("[sounds] missing or unreadable file \(sound.fileName, privacy: .public)")
            return nil
        }
        player.prepareToPlay()
        self.players[sound.fileName] = player
        return player
    }
}
