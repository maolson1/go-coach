import Foundation

/// Represents a Go rank from 20 kyu (index 0) up to 9 dan (index 28).
public struct GoRank: Hashable, Codable, Comparable, Identifiable, Sendable {
    /// 0 = 20k, 19 = 1k, 20 = 1d, 28 = 9d
    public let index: Int

    public var id: Int { index }

    public init(index: Int) {
        self.index = min(max(index, 0), 28)
    }

    public init(label: String) {
        let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasSuffix("k"), let num = Int(lower.dropLast()) {
            // 20k -> 0, 1k -> 19
            self.index = min(max(20 - num, 0), 19)
        } else if lower.hasSuffix("d"), let num = Int(lower.dropLast()) {
            // 1d -> 20, 9d -> 28
            self.index = min(max(19 + num, 20), 28)
        } else {
            self.index = 10 // default 10k
        }
    }

    public var label: String {
        if index < 20 {
            return "\(20 - index)k"
        } else {
            return "\(index - 19)d"
        }
    }

    public var displayName: String {
        if index < 20 {
            return "\(20 - index) Kyu"
        } else {
            return "\(index - 19) Dan"
        }
    }

    /// Maps directly to KataGo's Human SL profile string (e.g. "rank_10k", "rank_2d")
    public var kataGoHumanSLProfile: String {
        "rank_\(label)"
    }

    public static func < (lhs: GoRank, rhs: GoRank) -> Bool {
        lhs.index < rhs.index
    }

    public static let allRanks: [GoRank] = (0...28).map { GoRank(index: $0) }
}

@MainActor
public final class PlayerRatingManager: ObservableObject {
    private let defaults = UserDefaults.standard
    private let ratingKey = "GoCoach.continuousRating"
    private let autoAdjustKey = "GoCoach.autoAdjustStrength"
    private let gamesPlayedKey = "GoCoach.gamesPlayed"
    private let totalTokensSavedKey = "GoCoach.totalNormalMovesFiltered"

    /// Continuous rating where 10.0 == 10k, 19.0 == 1k, 20.0 == 1d
    @Published public var continuousRating: Double {
        didSet {
            let clamped = min(max(continuousRating, 0.0), 28.0)
            if clamped != continuousRating {
                continuousRating = clamped
            }
            defaults.set(continuousRating, forKey: ratingKey)
        }
    }

    @Published public var autoCalibrateStrength: Bool {
        didSet {
            defaults.set(autoCalibrateStrength, forKey: autoAdjustKey)
        }
    }

    @Published public var gamesPlayed: Int {
        didSet {
            defaults.set(gamesPlayed, forKey: gamesPlayedKey)
        }
    }

    @Published public var localMovesFilteredCount: Int {
        didSet {
            defaults.set(localMovesFilteredCount, forKey: totalTokensSavedKey)
        }
    }

    @Published public var lastRatingChangeNote: String? = nil

    public init() {
        if defaults.object(forKey: ratingKey) != nil {
            self.continuousRating = defaults.double(forKey: ratingKey)
        } else {
            self.continuousRating = 10.0 // Default 10k
        }
        if defaults.object(forKey: autoAdjustKey) != nil {
            self.autoCalibrateStrength = defaults.bool(forKey: autoAdjustKey)
        } else {
            self.autoCalibrateStrength = true
        }
        self.gamesPlayed = defaults.integer(forKey: gamesPlayedKey)
        self.localMovesFilteredCount = defaults.integer(forKey: totalTokensSavedKey)
    }

    public var currentRank: GoRank {
        GoRank(index: Int(continuousRating.rounded()))
    }

    public func setManualRank(_ rank: GoRank) {
        continuousRating = Double(rank.index)
        lastRatingChangeNote = "Rank set manually to \(rank.label)"
    }

    /// Updates player rating after a game (or partial game with >= 8 player moves)
    /// using both the game outcome and move accuracy relative to rank expectations.
    public func recordGamePerformance(
        playerWon: Bool?,
        playerMoveScoreLosses: [Double]
    ) {
        guard autoCalibrateStrength, !playerMoveScoreLosses.isEmpty else { return }

        let oldRank = currentRank
        let avgLoss = playerMoveScoreLosses.reduce(0.0, +) / Double(playerMoveScoreLosses.count)

        // Expected average score loss per move by rank:
        // 20k (idx 0) ~ 4.2 pts/move, 10k (idx 10) ~ 2.4 pts/move, 1d (idx 20) ~ 1.1 pts/move
        let expectedLossForRank = max(0.6, 4.2 - (continuousRating * 0.16))
        let accuracyDelta = (expectedLossForRank - avgLoss) * 0.18

        var outcomeDelta = 0.0
        if let won = playerWon {
            outcomeDelta = won ? 0.35 : -0.30
        }

        let totalDelta = min(max(accuracyDelta + outcomeDelta, -0.85), 0.85)
        continuousRating = min(max(continuousRating + totalDelta, 0.0), 28.0)
        gamesPlayed += 1

        let newRank = currentRank
        let sign = totalDelta >= 0 ? "+" : ""
        if newRank != oldRank {
            lastRatingChangeNote = String(
                format: "Rank updated: %@ → %@ (%@%.2f rating, avg loss %.1f pts/move)",
                oldRank.label, newRank.label, sign, totalDelta, avgLoss
            )
        } else {
            lastRatingChangeNote = String(
                format: "Rating %@%.2f (%@, avg loss %.1f pts/move)",
                sign, totalDelta, newRank.label, avgLoss
            )
        }
    }
}
