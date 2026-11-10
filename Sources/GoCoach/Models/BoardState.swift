import Foundation

public enum StoneColor: String, Codable, CaseIterable, Sendable {
    case black = "B"
    case white = "W"

    public var opponent: StoneColor {
        self == .black ? .white : .black
    }

    public var displayName: String {
        self == .black ? "Black" : "White"
    }
}

public struct BoardPoint: Hashable, Codable, Sendable {
    /// 0-indexed from left (0 ..< boardSize)
    public let col: Int
    /// 0-indexed from top (0 ..< boardSize)
    public let row: Int

    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }

    public func toGTP(boardSize: Int) -> String {
        let letters = Array("ABCDEFGHJKLMNOPQRST")
        guard col >= 0, col < letters.count, row >= 0, row < boardSize else {
            return "pass"
        }
        let goLine = boardSize - row
        return "\(letters[col])\(goLine)"
    }

    public static func fromGTP(_ gtp: String, boardSize: Int) -> BoardPoint? {
        let trimmed = gtp.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed == "PASS" || trimmed == "RESIGN" || trimmed.isEmpty {
            return nil
        }
        let letters = Array("ABCDEFGHJKLMNOPQRST")
        guard let firstChar = trimmed.first,
              let col = letters.firstIndex(of: firstChar),
              col < boardSize else {
            return nil
        }
        let numStr = String(trimmed.dropFirst())
        guard let goLine = Int(numStr), goLine >= 1, goLine <= boardSize else {
            return nil
        }
        let row = boardSize - goLine
        return BoardPoint(col: col, row: row)
    }

    public func neighbors(boardSize: Int) -> [BoardPoint] {
        var result: [BoardPoint] = []
        if col > 0 { result.append(BoardPoint(col: col - 1, row: row)) }
        if col + 1 < boardSize { result.append(BoardPoint(col: col + 1, row: row)) }
        if row > 0 { result.append(BoardPoint(col: col, row: row - 1)) }
        if row + 1 < boardSize { result.append(BoardPoint(col: col, row: row + 1)) }
        return result
    }

    public func manhattanDistance(to other: BoardPoint) -> Int {
        abs(col - other.col) + abs(row - other.row)
    }
}

public enum MoveAction: Equatable, Codable, Sendable {
    case place(BoardPoint)
    case pass

    public func toGTP(boardSize: Int) -> String {
        switch self {
        case .place(let pt):
            return pt.toGTP(boardSize: boardSize)
        case .pass:
            return "pass"
        }
    }

    public static func fromGTP(_ str: String, boardSize: Int) -> MoveAction {
        if let pt = BoardPoint.fromGTP(str, boardSize: boardSize) {
            return .place(pt)
        }
        return .pass
    }
}

public struct RecordedMove: Identifiable, Codable, Sendable {
    public let id: UUID
    public let moveNumber: Int
    public let color: StoneColor
    public let action: MoveAction
    public let capturedPoints: [BoardPoint]
    /// Black-perspective winrate (0.0 ... 1.0) after this move
    public var blackWinrateAfter: Double?
    /// Black-perspective score lead after this move
    public var blackScoreLeadAfter: Double?
    /// Points lost by this move from the mover's perspective
    public var scoreLoss: Double?
    /// Winrate drop (0.0 ... 100.0) from the mover's perspective
    public var winrateDropPercent: Double?

    public init(
        id: UUID = UUID(),
        moveNumber: Int,
        color: StoneColor,
        action: MoveAction,
        capturedPoints: [BoardPoint] = [],
        blackWinrateAfter: Double? = nil,
        blackScoreLeadAfter: Double? = nil,
        scoreLoss: Double? = nil,
        winrateDropPercent: Double? = nil
    ) {
        self.id = id
        self.moveNumber = moveNumber
        self.color = color
        self.action = action
        self.capturedPoints = capturedPoints
        self.blackWinrateAfter = blackWinrateAfter
        self.blackScoreLeadAfter = blackScoreLeadAfter
        self.scoreLoss = scoreLoss
        self.winrateDropPercent = winrateDropPercent
    }
}

public enum MoveLegalityError: Error, LocalizedError {
    case outOfBounds
    case occupied
    case suicide
    case koViolation

    public var errorDescription: String? {
        switch self {
        case .outOfBounds: return "That point is outside the board."
        case .occupied: return "There is already a stone at that intersection."
        case .suicide: return "Self-capture (suicide) is not allowed."
        case .koViolation: return "Ko rule prevents repeating the previous board position immediately."
        }
    }
}

public struct BoardState: Codable, Sendable, Equatable {
    public let size: Int
    public let komi: Double
    public let handicap: Int
    public private(set) var grid: [StoneColor?]
    public private(set) var nextToPlay: StoneColor
    public private(set) var initialPlayer: StoneColor = .black
    public private(set) var initialMoveNumber: Int = 0
    public private(set) var capturesByBlack: Int = 0
    public private(set) var capturesByWhite: Int = 0
    public private(set) var moveHistory: [RecordedMove] = []
    public private(set) var initialStones: [(StoneColor, BoardPoint)] = []
    private var positionHashes: Set<Int> = []
    public private(set) var koPoint: BoardPoint? = nil

    public var currentMoveNumber: Int {
        initialMoveNumber + moveHistory.count
    }

    public init(size: Int = 19, komi: Double = 6.5, handicap: Int = 0) {
        self.size = size
        self.komi = handicap >= 2 ? 0.5 : komi
        self.handicap = handicap
        self.grid = Array(repeating: nil, count: size * size)
        self.nextToPlay = .black
        self.initialPlayer = .black

        if handicap >= 2 {
            let hPoints = Self.handicapPoints(for: size, count: handicap)
            for pt in hPoints {
                self.grid[pt.row * size + pt.col] = .black
                self.initialStones.append((.black, pt))
            }
            self.nextToPlay = .white
            self.initialPlayer = .white
        }
        self.positionHashes.insert(computeGridHash(grid))
    }

    public init(
        size: Int = 19,
        komi: Double = 6.5,
        initialStones: [(StoneColor, BoardPoint)],
        initialPlayer: StoneColor = .black,
        initialMoveNumber: Int = 0
    ) {
        self.size = size
        self.komi = komi
        self.handicap = 0
        self.grid = Array(repeating: nil, count: size * size)
        self.nextToPlay = initialPlayer
        self.initialPlayer = initialPlayer
        self.initialMoveNumber = initialMoveNumber
        for (color, pt) in initialStones where pt.col >= 0 && pt.col < size && pt.row >= 0 && pt.row < size {
            self.grid[pt.row * size + pt.col] = color
            self.initialStones.append((color, pt))
        }
        self.positionHashes.insert(computeGridHash(grid))
    }

    public static func == (lhs: BoardState, rhs: BoardState) -> Bool {
        lhs.size == rhs.size &&
        lhs.grid == rhs.grid &&
        lhs.nextToPlay == rhs.nextToPlay &&
        lhs.initialMoveNumber == rhs.initialMoveNumber &&
        lhs.moveHistory.count == rhs.moveHistory.count
    }

    private enum CodingKeys: String, CodingKey {
        case size, komi, handicap, grid, nextToPlay, initialPlayer, initialMoveNumber, capturesByBlack, capturesByWhite, moveHistory, koPoint
    }

    public func stone(at point: BoardPoint) -> StoneColor? {
        guard isValid(point) else { return nil }
        return grid[point.row * size + point.col]
    }

    public func isValid(_ point: BoardPoint) -> Bool {
        point.col >= 0 && point.col < size && point.row >= 0 && point.row < size
    }

    public var consecutivePasses: Int {
        var count = 0
        for move in moveHistory.reversed() {
            if move.action == .pass {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    public var isGameOverByPasses: Bool {
        consecutivePasses >= 2
    }

    public var lastPlacedPoint: BoardPoint? {
        guard let last = moveHistory.last else { return nil }
        if case .place(let pt) = last.action {
            return pt
        }
        return nil
    }

    /// Returns group stones and their liberty points for the connected component at `start`.
    public func groupAndLiberties(at start: BoardPoint, in customGrid: [StoneColor?]? = nil) -> (stones: Set<BoardPoint>, liberties: Set<BoardPoint>) {
        let activeGrid = customGrid ?? grid
        guard isValid(start), let color = activeGrid[start.row * size + start.col] else {
            return ([], [])
        }
        var visited: Set<BoardPoint> = [start]
        var queue: [BoardPoint] = [start]
        var liberties: Set<BoardPoint> = []

        while let current = queue.popLast() {
            for nb in current.neighbors(boardSize: size) {
                let nbState = activeGrid[nb.row * size + nb.col]
                if nbState == nil {
                    liberties.insert(nb)
                } else if nbState == color && !visited.contains(nb) {
                    visited.insert(nb)
                    queue.append(nb)
                }
            }
        }
        return (visited, liberties)
    }

    public func canPlay(at point: BoardPoint, color: StoneColor? = nil) -> Result<[BoardPoint], MoveLegalityError> {
        let mover = color ?? nextToPlay
        guard isValid(point) else { return .failure(.outOfBounds) }
        guard stone(at: point) == nil else { return .failure(.occupied) }
        if point == koPoint {
            return .failure(.koViolation)
        }

        var testGrid = grid
        testGrid[point.row * size + point.col] = mover

        var captured: [BoardPoint] = []
        let opp = mover.opponent

        for nb in point.neighbors(boardSize: size) {
            if testGrid[nb.row * size + nb.col] == opp {
                let (group, libs) = groupAndLiberties(at: nb, in: testGrid)
                if libs.isEmpty {
                    for s in group {
                        testGrid[s.row * size + s.col] = nil
                        captured.append(s)
                    }
                }
            }
        }

        let (_, myLibs) = groupAndLiberties(at: point, in: testGrid)
        if myLibs.isEmpty {
            return .failure(.suicide)
        }

        let newHash = computeGridHash(testGrid)
        if positionHashes.contains(newHash) {
            return .failure(.koViolation)
        }

        return .success(captured)
    }

    @discardableResult
    public mutating func play(_ action: MoveAction, color: StoneColor? = nil) throws -> RecordedMove {
        let mover = color ?? nextToPlay
        let moveNum = initialMoveNumber + moveHistory.count + 1

        switch action {
        case .pass:
            koPoint = nil
            let rec = RecordedMove(moveNumber: moveNum, color: mover, action: .pass)
            moveHistory.append(rec)
            nextToPlay = mover.opponent
            return rec

        case .place(let point):
            switch canPlay(at: point, color: mover) {
            case .failure(let err):
                throw err
            case .success(let captured):
                let (_, myGroupBeforeCapture) = groupAndLiberties(at: point, in: {
                    var g = grid
                    g[point.row * size + point.col] = mover
                    return g
                }())

                grid[point.row * size + point.col] = mover
                for cap in captured {
                    grid[cap.row * size + cap.col] = nil
                }

                if mover == .black {
                    capturesByBlack += captured.count
                } else {
                    capturesByWhite += captured.count
                }

                // Simple ko point detection
                if captured.count == 1 && myGroupBeforeCapture.isEmpty {
                    koPoint = captured[0]
                } else {
                    koPoint = nil
                }

                positionHashes.insert(computeGridHash(grid))
                let rec = RecordedMove(
                    moveNumber: moveNum,
                    color: mover,
                    action: .place(point),
                    capturedPoints: captured
                )
                moveHistory.append(rec)
                nextToPlay = mover.opponent
                return rec
            }
        }
    }

    public mutating func updateLastMoveEvaluation(
        blackWinrate: Double,
        blackScoreLead: Double,
        scoreLoss: Double,
        winrateDropPercent: Double
    ) {
        guard !moveHistory.isEmpty else { return }
        let idx = moveHistory.count - 1
        moveHistory[idx].blackWinrateAfter = blackWinrate
        moveHistory[idx].blackScoreLeadAfter = blackScoreLead
        moveHistory[idx].scoreLoss = scoreLoss
        moveHistory[idx].winrateDropPercent = winrateDropPercent
    }

    private func computeGridHash(_ g: [StoneColor?]) -> Int {
        var hasher = Hasher()
        for cell in g {
            switch cell {
            case .none: hasher.combine(0)
            case .some(.black): hasher.combine(1)
            case .some(.white): hasher.combine(2)
            }
        }
        return hasher.finalize()
    }

    /// Game phase estimation for tactical digest
    public var gamePhase: String {
        let m = currentMoveNumber
        let scale = Double(size * size) / 361.0
        if Double(m) < 45.0 * scale {
            return "opening"
        } else if Double(m) < 150.0 * scale {
            return "middle game"
        } else {
            return "endgame"
        }
    }

    /// Detects tactical & classical 3x3 shape tags explaining why `playedMove` differs from `bestMove`
    public func analyzeTacticalTags(
        played: MoveAction,
        bestMoveGTP: String,
        bestSecondGTP: String? = nil,
        punishFirstGTP: String? = nil,
        mover: StoneColor,
        boardBeforeMove: BoardState
    ) -> [String] {
        var tags: [String] = []
        guard case .place(let playedPt) = played else {
            tags.append("slow_endgame")
            return tags
        }
        let bestPt = BoardPoint.fromGTP(bestMoveGTP, boardSize: size)
        let bestReplyPt = bestSecondGTP.flatMap { BoardPoint.fromGTP($0, boardSize: size) }
        let punishPt = punishFirstGTP.flatMap { BoardPoint.fromGTP($0, boardSize: size) }

        // Simulate playing KataGo's best move on `boardBeforeMove` so we can verify
        // whether an atari is truly urgent/sente vs small/dead (arXiv:2610.22953).
        var boardIfBest = boardBeforeMove
        if let bestPt = bestPt {
            _ = try? boardIfBest.play(.place(bestPt), color: mover)
        }

        // 1. Check if played move put own group into atari (self-atari)
        let (myGroup, myLibs) = groupAndLiberties(at: playedPt)
        if myLibs.count == 1 && myGroup.count >= 2 {
            tags.append("self_atari")
        }

        // 2. Atari vs. Sente verification on existing friendly groups (arXiv:2610.22953)
        var checkedAtariGroups: Set<BoardPoint> = []
        for r in 0..<size {
            for c in 0..<size {
                let pt = BoardPoint(col: c, row: r)
                guard !checkedAtariGroups.contains(pt), boardBeforeMove.stone(at: pt) == mover else { continue }
                let (grp, libsBefore) = boardBeforeMove.groupAndLiberties(at: pt)
                checkedAtariGroups.formUnion(grp)

                if libsBefore.count == 1 && grp.count >= 1 {
                    let (_, libsAfterPlayed) = groupAndLiberties(at: pt)
                    let (_, libsIfBest) = boardIfBest.groupAndLiberties(at: pt)

                    // Case A: KataGo's bestMove rescues this group (>= 2 liberties), while player's move left it in atari
                    if libsAfterPlayed.count <= 1 && libsIfBest.count >= 2 {
                        if !tags.contains("missed_atari_defense") {
                            tags.append("missed_atari_defense")
                        }
                    }
                    // Case B: Player rescued a group in atari (>= 2 liberties), but KataGo's bestMove ignored it
                    // (meaning the atari was NOT sente / stones were small or dead!)
                    else if libsAfterPlayed.count >= 2 && libsIfBest.count <= 1 {
                        if !tags.contains("saved_non_sente_atari") {
                            tags.append("saved_non_sente_atari")
                        }
                    }
                }
            }
        }

        // 2b. Check whether KataGo's bestPt plays a TRUE SENTE ATARI vs player playing a NON-SENTE ATARI
        let opp = mover.opponent
        if let bestPt = bestPt {
            for nb in bestPt.neighbors(boardSize: size) where boardIfBest.stone(at: nb) == opp {
                let (oppGrp, oppLibsIfBest) = boardIfBest.groupAndLiberties(at: nb)
                if oppLibsIfBest.count == 1 {
                    // Verify if opponent's top PV reply (`bestReplyPt`) is forced to respond locally
                    if let replyPt = bestReplyPt,
                       oppGrp.contains(where: { $0.manhattanDistance(to: replyPt) <= 2 }) {
                        if !tags.contains("missed_sente_atari") {
                            tags.append("missed_sente_atari")
                        }
                    }
                }
            }
        }

        for nb in playedPt.neighbors(boardSize: size) where stone(at: nb) == opp {
            let (oppGrp, oppLibsAfterPlayed) = groupAndLiberties(at: nb)
            if oppLibsAfterPlayed.count == 1, let punishPt = punishPt {
                let answeredLocally = oppGrp.contains(where: { $0.manhattanDistance(to: punishPt) <= 2 }) ||
                    punishPt.manhattanDistance(to: playedPt) <= 2
                if !answeredLocally && !tags.contains("played_non_sente_atari") {
                    tags.append("played_non_sente_atari")
                }
            }
        }

        // 3. Check for empty triangle created by playedPt
        for (dc, dr) in [(-1, -1), (-1, 1), (1, -1), (1, 1)] {
            let p1 = BoardPoint(col: playedPt.col + dc, row: playedPt.row)
            let p2 = BoardPoint(col: playedPt.col, row: playedPt.row + dr)
            let pDiag = BoardPoint(col: playedPt.col + dc, row: playedPt.row + dr)
            if isValid(p1), isValid(p2), isValid(pDiag) {
                let colors = [stone(at: p1), stone(at: p2), stone(at: pDiag)]
                let friendlyCount = colors.filter { $0 == mover }.count
                let nilCount = colors.filter { $0 == nil }.count
                if friendlyCount == 2 && nilCount == 1 {
                    tags.append("empty_triangle")
                    break
                }
            }
        }

        // 4. Check if bestPt connects two friendly groups or cuts opponent groups
        if let bestPt = bestPt {
            var friendlyNeighborGroups = 0
            var seenRoots: Set<BoardPoint> = []
            for nb in bestPt.neighbors(boardSize: size) {
                if boardBeforeMove.stone(at: nb) == mover {
                    let (grp, _) = boardBeforeMove.groupAndLiberties(at: nb)
                    if let rep = grp.first, !seenRoots.contains(rep) {
                        seenRoots.formUnion(grp)
                        friendlyNeighborGroups += 1
                    }
                }
            }
            if friendlyNeighborGroups >= 2 {
                tags.append("missed_cut_or_connection")
            }

            // 4b. Classical 3x3 Shape Templates on KataGo's recommended move (`bestPt`)
            if boardBeforeMove.isHaneAtHeadOfTwo(at: bestPt, mover: mover) {
                tags.append("missed_hane_at_head_of_two")
            }
            if boardBeforeMove.isTigersMouth(at: bestPt, mover: mover) {
                tags.append("missed_tigers_mouth")
            }
            if boardBeforeMove.isBambooJoint(at: bestPt, mover: mover) {
                tags.append("missed_bamboo_joint")
            }
            if boardBeforeMove.isPeepAtOnePointJump(at: bestPt, mover: mover) {
                tags.append("missed_peep_one_point_jump")
            }
        }

        // 4c. Check if played move allows an immediate classical shape punishment by opponent
        if let punishPt = punishPt {
            let opp = mover.opponent
            if isHaneAtHeadOfTwo(at: punishPt, mover: opp) {
                tags.append("allowed_opponent_hane_at_head_of_two")
            }
            if isPeepAtOnePointJump(at: punishPt, mover: opp) {
                tags.append("allowed_opponent_peep")
            }
            if isWedgeOrCrossCut(at: punishPt, mover: opp) {
                tags.append("allowed_opponent_wedge_or_cut")
            }
        }

        // 5. Tenuki from urgent local fight vs direction of play
        if let prevMove = boardBeforeMove.lastPlacedPoint, let bestPt = bestPt {
            if bestPt.manhattanDistance(to: prevMove) <= 3 && playedPt.manhattanDistance(to: prevMove) >= 6 {
                tags.append("tenuki_from_urgent")
            } else if bestPt.manhattanDistance(to: prevMove) >= 6 && playedPt.manhattanDistance(to: prevMove) <= 2 {
                tags.append("direction_of_play")
            }
        }

        // 6. Overplay invasion (surrounded by opponent stones with no friendly support nearby)
        var nearbyFriendly = 0
        var nearbyOpponent = 0
        for dr in -3...3 {
            for dc in -3...3 {
                if dr == 0 && dc == 0 { continue }
                let pt = BoardPoint(col: playedPt.col + dc, row: playedPt.row + dr)
                if let st = boardBeforeMove.stone(at: pt) {
                    if st == mover { nearbyFriendly += 1 }
                    else { nearbyOpponent += 1 }
                }
            }
        }
        if nearbyFriendly == 0 && nearbyOpponent >= 4 {
            tags.append("overplay_invasion")
        }

        if gamePhase == "endgame" && tags.isEmpty {
            tags.append("slow_endgame")
        }

        return tags
    }

    // MARK: - Classical 3x3 Shape Template Predicates

    /// Hane at the head of two stones: `pt` is directly in front of two aligned opponent stones
    /// while supported diagonally/orthogonally by a friendly stone alongside those opponent stones.
    public func isHaneAtHeadOfTwo(at pt: BoardPoint, mover: StoneColor) -> Bool {
        let opp = mover.opponent
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for (dc, dr) in dirs {
            let o1 = BoardPoint(col: pt.col + dc, row: pt.row + dr)
            let o2 = BoardPoint(col: pt.col + 2 * dc, row: pt.row + 2 * dr)
            guard stone(at: o1) == opp && stone(at: o2) == opp else { continue }

            // Perpendicular offsets to check our own stone running alongside o1/o2
            for (pc, pr) in [(-dr, dc), (dr, -dc)] {
                let f1 = BoardPoint(col: o1.col + pc, row: o1.row + pr)
                let f2 = BoardPoint(col: o2.col + pc, row: o2.row + pr)
                if stone(at: f1) == mover && (stone(at: f2) == mover || stone(at: BoardPoint(col: pt.col + pc, row: pt.row + pr)) == mover) {
                    return true
                }
            }
        }
        return false
    }

    /// Tiger's Mouth (Kake-tsugi): placing `mover` at `pt` creates an adjacent empty point
    /// surrounded on 3 orthogonal sides by `mover` stones (protecting a cut or eye).
    public func isTigersMouth(at pt: BoardPoint, mover: StoneColor) -> Bool {
        let opp = mover.opponent
        for mouth in pt.neighbors(boardSize: size) where stone(at: mouth) == nil {
            let nbs = mouth.neighbors(boardSize: size)
            guard nbs.count == 4 else { continue }
            var friendlySides = 0
            for nb in nbs {
                if nb == pt || stone(at: nb) == mover {
                    friendlySides += 1
                }
            }
            if friendlySides == 3 {
                // Verify there is an opponent stone near the mouth/diagonal making this a real shape protection
                for dr in -1...1 {
                    for dc in -1...1 {
                        let check = BoardPoint(col: mouth.col + dc, row: mouth.row + dr)
                        if stone(at: check) == opp {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    /// Bamboo Joint (Takefu): placing `mover` at `pt` completes two parallel pairs of friendly stones
    /// separated by a 1-line gap (`X . X` on two adjacent rows/cols).
    public func isBambooJoint(at pt: BoardPoint, mover: StoneColor) -> Bool {
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for (dc, dr) in dirs {
            let partner = BoardPoint(col: pt.col + dc, row: pt.row + dr)
            guard stone(at: partner) == mover else { continue }
            // Check 2 steps perpendicular
            for (pc, pr) in [(-dr, dc), (dr, -dc)] {
                let mid1 = BoardPoint(col: pt.col + pc, row: pt.row + pr)
                let mid2 = BoardPoint(col: partner.col + pc, row: partner.row + pr)
                let far1 = BoardPoint(col: pt.col + 2 * pc, row: pt.row + 2 * pr)
                let far2 = BoardPoint(col: partner.col + 2 * pc, row: partner.row + 2 * pr)
                if isValid(far1), isValid(far2),
                   stone(at: mid1) == nil, stone(at: mid2) == nil,
                   stone(at: far1) == mover, stone(at: far2) == mover {
                    return true
                }
            }
        }
        return false
    }

    /// Peep at a one-point jump (Nozoki): `pt` is orthogonally adjacent to an empty midpoint
    /// between two opponent stones separated by 1 intersection (`O . O`).
    public func isPeepAtOnePointJump(at pt: BoardPoint, mover: StoneColor) -> Bool {
        let opp = mover.opponent
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for (dc, dr) in dirs {
            let mid = BoardPoint(col: pt.col + dc, row: pt.row + dr)
            guard isValid(mid), stone(at: mid) == nil else { continue }
            let perp1 = BoardPoint(col: mid.col - dr, row: mid.row + dc)
            let perp2 = BoardPoint(col: mid.col + dr, row: mid.row - dc)
            if stone(at: perp1) == opp && stone(at: perp2) == opp {
                return true
            }
        }
        return false
    }

    /// Wedge or Cross-cut: `pt` is placed directly between two opponent stones (either colinear or diagonal cut).
    public func isWedgeOrCrossCut(at pt: BoardPoint, mover: StoneColor) -> Bool {
        let opp = mover.opponent
        let hLeft = BoardPoint(col: pt.col - 1, row: pt.row)
        let hRight = BoardPoint(col: pt.col + 1, row: pt.row)
        if stone(at: hLeft) == opp && stone(at: hRight) == opp {
            return true
        }
        let vUp = BoardPoint(col: pt.col, row: pt.row - 1)
        let vDown = BoardPoint(col: pt.col, row: pt.row + 1)
        if stone(at: vUp) == opp && stone(at: vDown) == opp {
            return true
        }
        return false
    }

    // MARK: - Group Life-and-Death & Ownership Shift Diff

    /// Compares KataGo's `ownership` heatmap before the move (assuming best play) vs after the move
    /// to identify any stone groups whose life-and-death / safety status changed, plus major regional swings.
    public func analyzeOwnershipShifts(
        preOwnership: [Double]?,
        postOwnership: [Double]?,
        mover: StoneColor,
        boardBeforeMove: BoardState,
        playedMove: MoveAction,
        bestMoveGTP: String? = nil
    ) -> [String] {
        guard let pre = preOwnership, let post = postOwnership,
              pre.count >= size * size, post.count >= size * size else {
            return []
        }

        var notes: [String] = []
        var visited: Set<BoardPoint> = []

        func statusLabel(for survival: Double) -> String {
            if survival >= 0.72 { return "alive/safe" }
            if survival >= 0.42 { return "unsettled" }
            return "dead/captured"
        }

        // 0. Check if KataGo's recommended `bestMoveGTP` itself has low survival in `preOwnership`
        // (identifying sacrificial forcing moves / kikashi probes like E18!)
        if let bestGTP = bestMoveGTP,
           let bestPt = BoardPoint.fromGTP(bestGTP, boardSize: size) {
            let sign: Double = (mover == .black) ? 1.0 : -1.0
            let idx = bestPt.row * size + bestPt.col
            let bestStoneSurvival = ((pre[idx] * sign) + 1.0) * 0.5
            if bestStoneSurvival < 0.36 {
                notes.append(
                    String(
                        format: "KataGo's best move %@ has only %d%% individual stone survival in KataGo's ownership map (played as a sacrificial forcing move / kikashi probe, not meant to live on its own)",
                        bestGTP,
                        Int((bestStoneSurvival * 100).rounded())
                    )
                )
            }
        }

        // 1. Check all existing groups on `boardBeforeMove` for life-and-death status changes
        var groupChanges: [(delta: Double, text: String)] = []
        for r in 0..<size {
            for c in 0..<size {
                let pt = BoardPoint(col: c, row: r)
                guard !visited.contains(pt), let gColor = boardBeforeMove.stone(at: pt) else { continue }
                let (stones, _) = boardBeforeMove.groupAndLiberties(at: pt)
                visited.formUnion(stones)

                let sign: Double = (gColor == .black) ? 1.0 : -1.0
                var sumPre = 0.0
                var sumPost = 0.0
                for s in stones {
                    let idx = s.row * size + s.col
                    // Convert [-1, 1] Black-perspective ownership into [0, 1] survival probability for `gColor`
                    let pPre = ((pre[idx] * sign) + 1.0) * 0.5
                    let pPost = ((post[idx] * sign) + 1.0) * 0.5
                    sumPre += pPre
                    sumPost += pPost
                }
                let survPre = sumPre / Double(stones.count)
                let survPost = sumPost / Double(stones.count)
                let sortedGTP = stones.map { $0.toGTP(boardSize: size) }.sorted()
                let sampleCoords = sortedGTP.prefix(3).joined(separator: ",")

                if gColor == mover {
                    let drop = survPre - survPost
                    if drop >= 0.20 {
                        let beforeLbl = statusLabel(for: survPre)
                        let afterLbl = statusLabel(for: survPost)
                        let desc = String(
                            format: "Your %d-stone group [%@] dropped from %d%% (%@) to %d%% (%@) survival",
                            stones.count, sampleCoords, Int((survPre * 100).rounded()), beforeLbl, Int((survPost * 100).rounded()), afterLbl
                        )
                        groupChanges.append((drop, desc))
                    }
                } else {
                    let gain = survPost - survPre
                    if gain >= 0.20 {
                        let beforeLbl = statusLabel(for: survPre)
                        let afterLbl = statusLabel(for: survPost)
                        let desc = String(
                            format: "Opponent's %d-stone group [%@] stabilized from %d%% (%@) to %d%% (%@) survival",
                            stones.count, sampleCoords, Int((survPre * 100).rounded()), beforeLbl, Int((survPost * 100).rounded()), afterLbl
                        )
                        groupChanges.append((gain, desc))
                    }
                }
            }
        }

        groupChanges.sort { $0.delta > $1.delta }
        for item in groupChanges.prefix(2) {
            notes.append(item.text)
        }

        // 2. Check the newly placed stone's own survival if it wasn't part of an existing group change
        if case .place(let playedPt) = playedMove {
            let sign: Double = (mover == .black) ? 1.0 : -1.0
            let idx = playedPt.row * size + playedPt.col
            let newlyPlacedSurvival = ((post[idx] * sign) + 1.0) * 0.5
            if newlyPlacedSurvival < 0.32 {
                notes.append(
                    String(
                        format: "The newly played stone at %@ has only %d%% expected survival (likely captured or overplay)",
                        playedPt.toGTP(boardSize: size),
                        Int((newlyPlacedSurvival * 100).rounded())
                    )
                )
            }
        }

        // 3. If no stone group changed life/death status, report the board region with the largest territory loss
        if notes.isEmpty {
            let moverSign: Double = (mover == .black) ? 1.0 : -1.0
            var regionLoss: [String: Double] = [:]
            for r in 0..<size {
                for c in 0..<size {
                    let idx = r * size + c
                    let pointLoss = (pre[idx] - post[idx]) * moverSign * 0.5
                    if pointLoss > 0.05 {
                        let region = sectorName(col: c, row: r)
                        regionLoss[region, default: 0.0] += pointLoss
                    }
                }
            }
            if let (topRegion, pts) = regionLoss.max(by: { $0.value < $1.value }), pts >= 1.5 {
                notes.append(String(format: "Lost ~%.1f pts of territory/influence in the %@", pts, topRegion))
            }
        }

        return notes
    }

    private func sectorName(col: Int, row: Int) -> String {
        let third = max(3, size / 3)
        let vPart: String
        if row < third { vPart = "Top" }
        else if row >= size - third { vPart = "Bottom" }
        else { vPart = "Middle" }

        let hPart: String
        if col < third { hPart = "Left" }
        else if col >= size - third { hPart = "Right" }
        else { hPart = "Center" }

        switch (vPart, hPart) {
        case ("Top", "Left"): return "Top-Left corner"
        case ("Top", "Right"): return "Top-Right corner"
        case ("Bottom", "Left"): return "Bottom-Left corner"
        case ("Bottom", "Right"): return "Bottom-Right corner"
        case ("Top", "Center"): return "Top side"
        case ("Bottom", "Center"): return "Bottom side"
        case ("Middle", "Left"): return "Left side"
        case ("Middle", "Right"): return "Right side"
        default: return "Center"
        }
    }

    /// Simulates the Principal Variations (`bestPV` and `punishPV`) on copies of `baseBoard`
    /// to extract verified end-of-sequence captures, forcing ataris, cross-board switches, and liberty counts.
    public static func summarizePVOutcomes(
        baseBoard: BoardState,
        mover: StoneColor,
        bestPV: [String],
        punishPV: [String]
    ) -> [String] {
        var summaries: [String] = []
        let size = baseBoard.size

        if !bestPV.isEmpty {
            var sim = baseBoard
            var turn = mover
            var moverCaptured: [String] = []
            var oppCaptured: [String] = []
            var forcingAtaris: [String] = []
            var crossBoardSwitch: String? = nil
            let startPt = BoardPoint.fromGTP(bestPV[0], boardSize: size)

            for gtp in bestPV.prefix(8) {
                let act = MoveAction.fromGTP(gtp, boardSize: size)
                if let pt = BoardPoint.fromGTP(gtp, boardSize: size) {
                    if turn == mover, let sPt = startPt, sPt.manhattanDistance(to: pt) > 6, crossBoardSwitch == nil {
                        let startQuad = baseBoard.sectorName(col: sPt.col, row: sPt.row)
                        let targetQuad = baseBoard.sectorName(col: pt.col, row: pt.row)
                        let onSameDiagonal = abs((pt.col - pt.row) - (sPt.col - sPt.row)) <= 3 || abs((pt.col + pt.row) - (sPt.col + sPt.row)) <= 3
                        let isWedge = sim.isWedgeOrCrossCut(at: pt, mover: mover)

                        // Collect adjacent opponent groups at the distant target point
                        var adjOppDescs: [String] = []
                        var seenReps: Set<BoardPoint> = []
                        for nb in pt.neighbors(boardSize: size) where sim.stone(at: nb) == mover.opponent {
                            let (grp, libs) = sim.groupAndLiberties(at: nb)
                            if let rep = grp.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).first, !seenReps.contains(rep) {
                                seenReps.insert(rep)
                                let sample = grp.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).prefix(3).map { $0.toGTP(boardSize: size) }.joined(separator: ",")
                                adjOppDescs.append("\(grp.count)-stone [\(sample)] (\(libs.count) libs)")
                            }
                        }

                        var detail = "plays forcing sequence in \(startQuad) then switches in sente to \(gtp) in \(targetQuad)"
                        if forcingAtaris.count >= 2 && onSameDiagonal {
                            detail = "chases opponent in a diagonal ladder/atari sequence in \(startQuad) (\(forcingAtaris.joined(separator: ", "))) aimed at the \(targetQuad) ladder-breaker, then plays \(gtp) in sente"
                        }
                        if isWedge && !adjOppDescs.isEmpty {
                            detail += " — wedging/cutting between opponent's \(adjOppDescs.joined(separator: " and ")) to create a double threat"
                        } else if !adjOppDescs.isEmpty {
                            detail += " — directly attacking opponent's \(adjOppDescs.joined(separator: " and "))"
                        }
                        crossBoardSwitch = detail
                    }
                }
                if let rec = try? sim.play(act, color: turn) {
                    let capGTPs = rec.capturedPoints.map { $0.toGTP(boardSize: size) }
                    if turn == mover {
                        moverCaptured.append(contentsOf: capGTPs)
                        if case .place(let pt) = act {
                            for nb in pt.neighbors(boardSize: size) where sim.stone(at: nb) == mover.opponent {
                                let (_, libs) = sim.groupAndLiberties(at: nb)
                                if libs.count == 1 && !forcingAtaris.contains(gtp) {
                                    forcingAtaris.append(gtp)
                                }
                            }
                        }
                    } else {
                        oppCaptured.append(contentsOf: capGTPs)
                    }
                }
                turn = turn.opponent
            }
            var parts: [String] = []
            if !forcingAtaris.isEmpty {
                parts.append("gives forcing atari at \(forcingAtaris.joined(separator: ", "))")
            }
            if let switchDesc = crossBoardSwitch {
                parts.append(switchDesc)
            } else if forcingAtaris.count >= 3,
                      let firstAtariPt = BoardPoint.fromGTP(forcingAtaris[0], boardSize: size),
                      let lastAtariPt = BoardPoint.fromGTP(forcingAtaris.last!, boardSize: size) {
                let allPts = forcingAtaris.compactMap { BoardPoint.fromGTP($0, boardSize: size) }
                let totalDRow = allPts.reduce(0) { $0 + ($1.row - firstAtariPt.row) }
                let totalDCol = allPts.reduce(0) { $0 + ($1.col - firstAtariPt.col) }
                if abs(totalDRow) >= 1 && abs(totalDCol) >= 1 {
                    let stepR = totalDRow > 0 ? 1 : -1
                    let stepC = totalDCol > 0 ? 1 : -1
                    var hitOppPt: BoardPoint? = nil
                    outerLoop: for k in 1..<size {
                        for (dr, dc) in [(0, 0), (0, stepC), (stepR, 0), (-stepR, stepC), (stepR, -stepC)] {
                            let r = lastAtariPt.row + k * stepR + dr
                            let c = lastAtariPt.col + k * stepC + dc
                            let p = BoardPoint(col: c, row: r)
                            if baseBoard.isValid(p), baseBoard.stone(at: p) == mover.opponent, p.manhattanDistance(to: lastAtariPt) > 3 {
                                hitOppPt = p
                                break outerLoop
                            }
                        }
                    }
                    if let breakerPt = hitOppPt {
                        let breakerGTP = breakerPt.toGTP(boardSize: size)
                        let destQuad = baseBoard.sectorName(col: breakerPt.col, row: breakerPt.row)
                        // Also find any other opponent group within 2 intersections of `breakerPt`
                        var nearbyGroups: [String] = []
                        var seenReps: Set<BoardPoint> = []
                        for r in max(0, breakerPt.row - 2)...min(size - 1, breakerPt.row + 2) {
                            for c in max(0, breakerPt.col - 2)...min(size - 1, breakerPt.col + 2) {
                                let np = BoardPoint(col: c, row: r)
                                if baseBoard.stone(at: np) == mover.opponent {
                                    let (grp, libs) = baseBoard.groupAndLiberties(at: np)
                                    if let rep = grp.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).first, !seenReps.contains(rep) {
                                        seenReps.insert(rep)
                                        let sample = grp.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }).prefix(3).map { $0.toGTP(boardSize: size) }.joined(separator: ",")
                                        nearbyGroups.append("\(grp.count)-stone [\(sample)] (\(libs.count) libs)")
                                    }
                                }
                            }
                        }
                        parts.append("drives a diagonal broken-ladder chase (\(forcingAtaris.joined(separator: ", "))) aimed directly at opponent's ladder-breaker \(breakerGTP) and \(nearbyGroups.joined(separator: " / ")) in \(destQuad) to set up a double attack")
                    }
                }
            }
            if !moverCaptured.isEmpty {
                parts.append("captures \(moverCaptured.count) stone(s) [\(moverCaptured.prefix(3).joined(separator: ","))]")
            }
            if !oppCaptured.isEmpty {
                parts.append("sacrifices \(oppCaptured.count) stone(s) [\(oppCaptured.prefix(3).joined(separator: ","))]")
            }
            if let firstPt = startPt, sim.stone(at: firstPt) == mover {
                let (grp, libs) = sim.groupAndLiberties(at: firstPt)
                parts.append("\(bestPV[0]) group ends PV with \(grp.count) stone(s) and \(libs.count) liberties")
            }
            if !parts.isEmpty {
                summaries.append("Best PV outcome: " + parts.joined(separator: "; "))
            }
        }

        if !punishPV.isEmpty {
            var sim = baseBoard
            var turn = mover
            var moverCaptured: [String] = []
            var oppCaptured: [String] = []
            for gtp in punishPV.prefix(6) {
                let act = MoveAction.fromGTP(gtp, boardSize: size)
                if let rec = try? sim.play(act, color: turn) {
                    let capGTPs = rec.capturedPoints.map { $0.toGTP(boardSize: size) }
                    if turn == mover { moverCaptured.append(contentsOf: capGTPs) }
                    else { oppCaptured.append(contentsOf: capGTPs) }
                }
                turn = turn.opponent
            }
            var parts: [String] = []
            if !oppCaptured.isEmpty {
                parts.append("opponent captures \(oppCaptured.count) of your stone(s) [\(oppCaptured.prefix(3).joined(separator: ","))]")
            }
            if let firstPt = BoardPoint.fromGTP(punishPV[0], boardSize: size), sim.stone(at: firstPt) == mover {
                let (_, libs) = sim.groupAndLiberties(at: firstPt)
                parts.append("your \(punishPV[0]) group ends PV with \(libs.count) liberties")
            }
            if !parts.isEmpty {
                summaries.append("Punishment PV outcome: " + parts.joined(separator: "; "))
            }
        }

        return summaries
    }

    /// Parses Go board coordinates (e.g. "E18", "C14", "D4") mentioned in a user's natural-language question.
    public static func extractMentionedCoordinates(from question: String, boardSize: Int) -> [BoardPoint] {
        let pattern = #"\b([A-HJ-Ta-hj-t])(1[0-9]|[1-9])\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(question.startIndex..<question.endIndex, in: question)
        let matches = regex.matches(in: question, range: nsRange)

        var points: [BoardPoint] = []
        var seen: Set<BoardPoint> = []
        for match in matches {
            guard let r = Range(match.range, in: question) else { continue }
            let token = String(question[r]).uppercased()
            if let pt = BoardPoint.fromGTP(token, boardSize: boardSize), !seen.contains(pt) {
                seen.insert(pt)
                points.append(pt)
            }
        }
        return Array(points.prefix(2))
    }

    /// Generates a compact (~150-260 token) tactical digest for the LLM coach
    public func buildCompactTacticalDigest(
        playerRank: String,
        playedMove: RecordedMove?,
        bestMoveInfo: KataGoMoveInfo?,
        secondMoveInfo: KataGoMoveInfo?,
        punishmentPV: [String],
        scoreLoss: Double,
        winrateDropPercent: Double,
        scoreLeadAfter: Double,
        tacticalTags: [String],
        ownershipShifts: [String] = [],
        pvOutcomes: [String] = [],
        humanReplyRefutationLine: String? = nil,
        effectiveBestPV: [String]? = nil,
        counterfactualNotes: [String] = []
    ) -> String {
        let recentSlice = moveHistory.suffix(6)
        let recentStr = recentSlice.map { "\($0.moveNumber):\($0.color.rawValue) \($0.action.toGTP(boardSize: size))" }.joined(separator: ", ")

        // Local stones around the action point (9x9 window) to keep token count minimal
        let focusPt: BoardPoint? = {
            if let pm = playedMove, case .place(let pt) = pm.action { return pt }
            if let bm = bestMoveInfo, let pt = BoardPoint.fromGTP(bm.move, boardSize: size) { return pt }
            return lastPlacedPoint
        }()

        var localBlack: [String] = []
        var localWhite: [String] = []
        if let center = focusPt {
            for r in max(0, center.row - 4)...min(size - 1, center.row + 4) {
                for c in max(0, center.col - 4)...min(size - 1, center.col + 4) {
                    let pt = BoardPoint(col: c, row: r)
                    if let s = stone(at: pt) {
                        if s == .black { localBlack.append(pt.toGTP(boardSize: size)) }
                        else { localWhite.append(pt.toGTP(boardSize: size)) }
                    }
                }
            }
        }

        // Include stones around both `bestMoveInfo` (if different from `focusPt`) and any distant PV target (`manhattanDistance > 6`)
        let pvToInspect = effectiveBestPV ?? bestMoveInfo?.pv ?? []
        var extraRegionLines: [String] = []
        var coveredCenters: [BoardPoint] = focusPt.map { [$0] } ?? []

        for gtp in pvToInspect.prefix(8) {
            if let pt = BoardPoint.fromGTP(gtp, boardSize: size),
               coveredCenters.allSatisfy({ $0.manhattanDistance(to: pt) > 6 }) {
                coveredCenters.append(pt)
                var distB: [String] = []
                var distW: [String] = []
                for r in max(0, pt.row - 3)...min(size - 1, pt.row + 3) {
                    for c in max(0, pt.col - 3)...min(size - 1, pt.col + 3) {
                        let p = BoardPoint(col: c, row: r)
                        if let s = stone(at: p) {
                            if s == .black { distB.append(p.toGTP(boardSize: size)) }
                            else { distW.append(p.toGTP(boardSize: size)) }
                        }
                    }
                }
                if !distB.isEmpty || !distW.isEmpty {
                    let quad = sectorName(col: pt.col, row: pt.row)
                    extraRegionLines.append("Stones near PV coordinate \(gtp) (\(quad)): B[\(distB.prefix(12).joined(separator: ","))] W[\(distW.prefix(12).joined(separator: ","))]")
                }
            }
        }

        var lines: [String] = []
        lines.append("Board: \(size)x\(size) | Move #\(currentMoveNumber) (\(gamePhase)) | Student Rank: \(playerRank)")
        if !recentStr.isEmpty {
            lines.append("Recent moves: \(recentStr)")
        }
        if !localBlack.isEmpty || !localWhite.isEmpty {
            lines.append("Local stones near focus: B[\(localBlack.prefix(14).joined(separator: ","))] W[\(localWhite.prefix(14).joined(separator: ","))]")
        }
        lines.append(contentsOf: extraRegionLines)
        if let pm = playedMove {
            let gtp = pm.action.toGTP(boardSize: size)
            lines.append(String(format: "Student (%@) played: %@ (Lost %.1f pts, -%.0f%% winrate; Score now: %+.1f B)", pm.color.displayName, gtp, scoreLoss, winrateDropPercent, scoreLeadAfter))
        }
        if !punishmentPV.isEmpty {
            lines.append("Opponent punishment PV: \(punishmentPV.prefix(6).joined(separator: " -> "))")
        }
        if let best = bestMoveInfo {
            let pv = (effectiveBestPV ?? best.pv).prefix(8).joined(separator: " -> ")
            let hpStr = (best.humanPrior ?? -1) >= 0 ? String(format: ", Human SL prior: %.0f%%", (best.humanPrior ?? 0) * 100.0) : ""
            lines.append(String(format: "KataGo Best Move: %@ (Score: %+.1f B, Winrate: %.0f%%%@, PV: %@)", best.move, best.scoreLead, best.winrate * 100.0, hpStr, pv))
        }
        if let refLine = humanReplyRefutationLine {
            lines.append(refLine)
        }
        if let second = secondMoveInfo {
            let pv = second.pv.prefix(5).joined(separator: " -> ")
            let hpStr = (second.humanPrior ?? -1) >= 0 ? String(format: ", Human SL prior: %.0f%%", (second.humanPrior ?? 0) * 100.0) : ""
            lines.append(String(format: "2nd Alternative: %@ (Score: %+.1f B, Winrate: %.0f%%%@, PV: %@)", second.move, second.scoreLead, second.winrate * 100.0, hpStr, pv))
        }
        if !tacticalTags.isEmpty {
            lines.append("Detected tactical patterns: \(tacticalTags.joined(separator: ", "))")
        }
        if !ownershipShifts.isEmpty {
            lines.append("Group life/death & ownership shift: \(ownershipShifts.joined(separator: "; "))")
        }
        if !pvOutcomes.isEmpty {
            lines.append("Verified PV outcomes: \(pvOutcomes.joined(separator: " | "))")
        }
        if !counterfactualNotes.isEmpty {
            lines.append("[KataGo Counterfactual Verification for Student's Question]\n" + counterfactualNotes.joined(separator: "\n"))
        }
        lines.append("Explain in 2-3 concise, encouraging sentences why the student's move lost value and the human Go concept behind KataGo's preferred move.")
        return lines.joined(separator: "\n")
    }

    /// Summary of an SGF string for UI preview before starting a game.
    public struct SGFInspection: Equatable, Sendable {
        public let boardSize: Int
        public let komi: Double
        public let setupStoneCount: Int
        public let totalMoves: Int
    }

    /// Inspects an SGF string and returns its board size, setup stone count, and total move count if valid.
    public static func inspectSGF(_ rawSGF: String) -> SGFInspection? {
        let trimmed = rawSGF.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.contains("[") && trimmed.contains("]") else {
            return nil
        }
        guard let fullBoard = fromSGF(trimmed, upToMove: nil, initialMoveOffset: 0) else {
            return nil
        }
        guard !fullBoard.initialStones.isEmpty || !fullBoard.moveHistory.isEmpty || trimmed.contains("SZ[") || trimmed.contains("GM[") else {
            return nil
        }
        return SGFInspection(
            boardSize: fullBoard.size,
            komi: fullBoard.komi,
            setupStoneCount: fullBoard.initialStones.count,
            totalMoves: fullBoard.moveHistory.count
        )
    }

    /// Strips SGF text properties (`C[...]`, `GC[...]`, `PB[...]`, `PW[...]`, `EV[...]`, `GN[...]`, `RO[...]`, `SO[...]`, `AN[...]`, `US[...]`)
    /// so bracketed text or coordinates inside comments never confuse move parsing or leak metadata.
    private static func stripSGFTextProperties(_ sgf: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?:C|GC|PB|PW|EV|GN|RO|SO|AN|US)\[(?:\\.|[^\]])*\]"#, options: [.dotMatchesLineSeparators]) else {
            return sgf
        }
        let nsRange = NSRange(sgf.startIndex..<sgf.endIndex, in: sgf)
        return regex.stringByReplacingMatches(in: sgf, range: nsRange, withTemplate: "")
    }

    /// Parses an SGF string (supporting both `AB[..]`/`AW[..]` setup stones and `;B[..]`/`;W[..]` move sequences)
    /// up to `maxMove` without preserving any external metadata (player names, event titles, or comments).
    public static func fromSGF(_ rawSGF: String, upToMove maxMove: Int? = nil, initialMoveOffset: Int = 0) -> BoardState? {
        let sgf = stripSGFTextProperties(rawSGF)
        let trimmed = sgf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("[") && trimmed.contains("]") else {
            return nil
        }

        func sgfCoordToPoint(_ code: String, size: Int) -> BoardPoint? {
            let clean = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard clean.count == 2 else { return nil }
            let chars = Array(clean)
            let col = Int(chars[0].asciiValue ?? 0) - Int(Character("a").asciiValue!)
            let row = Int(chars[1].asciiValue ?? 0) - Int(Character("a").asciiValue!)
            guard col >= 0 && col < size && row >= 0 && row < size else { return nil }
            return BoardPoint(col: col, row: row)
        }

        var boardSize = 19
        if let szRange = sgf.range(of: #"SZ\[(\d+)\]"#, options: .regularExpression) {
            let matchStr = String(sgf[szRange])
            let digits = matchStr.filter(\.isNumber)
            if let parsed = Int(digits), [9, 13, 19].contains(parsed) {
                boardSize = parsed
            }
        }

        var komi = 6.5
        if let kmRange = sgf.range(of: #"KM\[([0-9.\-]+)\]"#, options: .regularExpression) {
            let matchStr = String(sgf[kmRange])
            if let open = matchStr.firstIndex(of: "["), let close = matchStr.firstIndex(of: "]") {
                let valStr = String(matchStr[matchStr.index(after: open)..<close])
                if let parsed = Double(valStr) {
                    komi = parsed
                }
            }
        }

        func extractSetupCoords(tag: String) -> [BoardPoint] {
            var pts: [BoardPoint] = []
            let pattern = tag + #"(\s*\[[a-sA-S]{2}\])+"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let nsRange = NSRange(sgf.startIndex..<sgf.endIndex, in: sgf)
            for match in regex.matches(in: sgf, range: nsRange) {
                guard let r = Range(match.range, in: sgf) else { continue }
                let block = String(sgf[r])
                if let coordRegex = try? NSRegularExpression(pattern: #"\[([a-sA-S]{2})\]"#) {
                    let bRange = NSRange(block.startIndex..<block.endIndex, in: block)
                    for cm in coordRegex.matches(in: block, range: bRange) {
                        if let cr = Range(cm.range(at: 1), in: block),
                           let pt = sgfCoordToPoint(String(block[cr]), size: boardSize) {
                            pts.append(pt)
                        }
                    }
                }
            }
            return pts
        }

        let abPts = extractSetupCoords(tag: "AB")
        let awPts = extractSetupCoords(tag: "AW")
        var setupStones: [(StoneColor, BoardPoint)] = []
        for pt in abPts { setupStones.append((.black, pt)) }
        for pt in awPts { setupStones.append((.white, pt)) }

        var nextPlayer: StoneColor = (abPts.count >= 2 && awPts.isEmpty) ? .white : .black
        if sgf.range(of: #"PL\[W\]"#, options: .regularExpression) != nil {
            nextPlayer = .white
        } else if sgf.range(of: #"PL\[B\]"#, options: .regularExpression) != nil {
            nextPlayer = .black
        }

        var board = BoardState(
            size: boardSize,
            komi: komi,
            initialStones: setupStones,
            initialPlayer: nextPlayer,
            initialMoveNumber: initialMoveOffset
        )

        if let moveRegex = try? NSRegularExpression(pattern: #"(?:^|;|\]|\s)([BW])\[([a-sA-S]{0,2})\]"#) {
            let nsRange = NSRange(sgf.startIndex..<sgf.endIndex, in: sgf)
            var count = 0
            for match in moveRegex.matches(in: sgf, range: nsRange) {
                if let limit = maxMove, count >= limit {
                    break
                }
                guard let cRange = Range(match.range(at: 1), in: sgf),
                      let pRange = Range(match.range(at: 2), in: sgf) else { continue }
                let color: StoneColor = (sgf[cRange].uppercased() == "B") ? .black : .white
                let coordStr = String(sgf[pRange])
                let action: MoveAction
                if coordStr.isEmpty || (boardSize <= 19 && coordStr.lowercased() == "tt") {
                    action = .pass
                } else if let pt = sgfCoordToPoint(coordStr, size: boardSize) {
                    action = .place(pt)
                } else {
                    continue
                }
                if (try? board.play(action, color: color)) != nil {
                    count += 1
                }
            }
        }

        guard !board.initialStones.isEmpty || !board.moveHistory.isEmpty || sgf.contains("SZ[") || sgf.contains("GM[") else {
            return nil
        }

        return board
    }

    /// Exports the game to standard SGF (Smart Game Format)
    public func toSGF(playerBlackName: String = "Black", playerWhiteName: String = "White") -> String {
        let letters = Array("abcdefghijklmnopqrst")
        func sgfCoord(_ pt: BoardPoint) -> String {
            guard pt.col < letters.count && pt.row < letters.count else { return "" }
            return "\(letters[pt.col])\(letters[pt.row])"
        }

        var sgf = "(;GM[1]FF[4]CA[UTF-8]AP[GoCoach:1.0]SZ[\(size)]KM[\(String(format: "%.1f", komi))]PB[\(playerBlackName)]PW[\(playerWhiteName)]"
        if handicap >= 2 {
            sgf += "HA[\(handicap)]AB"
            for (_, pt) in initialStones {
                sgf += "[\(sgfCoord(pt))]"
            }
        }
        for move in moveHistory {
            let tag = move.color == .black ? "B" : "W"
            switch move.action {
            case .pass:
                sgf += ";\(tag)[]"
            case .place(let pt):
                sgf += ";\(tag)[\(sgfCoord(pt))]"
            }
            if let loss = move.scoreLoss, loss >= 3.0 {
                sgf += "C[Score loss: -\(String(format: "%.1f", loss)) pts]"
            }
        }
        sgf += ")"
        return sgf
    }

    /// Standard star points (Hoshi) for 9x9, 13x13, 19x19
    public static func starPoints(for size: Int) -> [BoardPoint] {
        switch size {
        case 9:
            return [
                BoardPoint(col: 2, row: 2), BoardPoint(col: 6, row: 2),
                BoardPoint(col: 4, row: 4),
                BoardPoint(col: 2, row: 6), BoardPoint(col: 6, row: 6)
            ]
        case 13:
            return [
                BoardPoint(col: 3, row: 3), BoardPoint(col: 9, row: 3),
                BoardPoint(col: 6, row: 6),
                BoardPoint(col: 3, row: 9), BoardPoint(col: 9, row: 9)
            ]
        case 19:
            let coords = [3, 9, 15]
            var pts: [BoardPoint] = []
            for r in coords {
                for c in coords {
                    pts.append(BoardPoint(col: c, row: r))
                }
            }
            return pts
        default:
            return []
        }
    }

    public static func handicapPoints(for size: Int, count: Int) -> [BoardPoint] {
        let low: Int
        let mid: Int
        let high: Int
        switch size {
        case 9:
            (low, mid, high) = (2, 4, 6)
        case 13:
            (low, mid, high) = (3, 6, 9)
        case 19:
            (low, mid, high) = (3, 9, 15)
        default:
            return []
        }

        let tr = BoardPoint(col: high, row: low)
        let bl = BoardPoint(col: low, row: high)
        let br = BoardPoint(col: high, row: high)
        let tl = BoardPoint(col: low, row: low)
        let ml = BoardPoint(col: low, row: mid)
        let mr = BoardPoint(col: high, row: mid)
        let tm = BoardPoint(col: mid, row: low)
        let bm = BoardPoint(col: mid, row: high)
        let cc = BoardPoint(col: mid, row: mid)

        switch count {
        case 2: return [tr, bl]
        case 3: return [tr, bl, br]
        case 4: return [tr, bl, br, tl]
        case 5: return [tr, bl, br, tl, cc]
        case 6: return [tr, bl, br, tl, ml, mr]
        case 7: return [tr, bl, br, tl, ml, mr, cc]
        case 8: return [tr, bl, br, tl, ml, mr, tm, bm]
        default: return [tr, bl, br, tl, ml, mr, tm, bm, cc]
        }
    }
}
