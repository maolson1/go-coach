import AppKit
import Foundation
import SwiftUI

public struct VariationStep: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let stepNumber: Int
    public let color: StoneColor
    public let point: BoardPoint
    public let gtp: String
}

public struct VariationBranch: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let isRecommended: Bool
    public let baseBoard: BoardState
    public let steps: [VariationStep]
}

public struct BlunderIntervention: Equatable, Sendable {
    public let moveNumber: Int
    public let playedMoveGTP: String
    public let bestMoveGTP: String
    public let scoreLoss: Double
    public let winrateDropPercent: Double
    public let severityLabel: String
    public let boardBeforeMove: BoardState
    public let preAnalysis: KataGoAnalysisResponse
    public let postAnalysis: KataGoAnalysisResponse
}

public struct ReviewedMistake: Identifiable, Equatable, Sendable {
    public var id: Int { moveNumber }
    public let moveNumber: Int
    public let color: StoneColor
    public let playedMove: RecordedMove
    public let playedMoveGTP: String
    public var bestMoveGTP: String
    public let scoreLoss: Double
    public let winrateDropPercent: Double
    public let severityLabel: String
    public let boardBeforeMove: BoardState
    public let boardAfterMove: BoardState
    public var preAnalysis: KataGoAnalysisResponse
    public var postAnalysis: KataGoAnalysisResponse
    public var explanation: String? = nil
    public var explanationSourceBadge: String? = nil
}

public struct ChatEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: String // "coach" or "student"
    public var text: String
    public let moveNumber: Int
    public let sourceBadge: String?

    public init(id: UUID = UUID(), role: String, text: String, moveNumber: Int, sourceBadge: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.moveNumber = moveNumber
        self.sourceBadge = sourceBadge
    }
}

@MainActor
public final class GameSession: ObservableObject {
    @Published public var board: BoardState
    @Published public var humanColor: StoneColor = .black
    @Published public var isEngineThinking: Bool = false
    @Published public var isCoachStreaming: Bool = false
    @Published public var statusText: String = "Your turn to play"
    @Published public var errorBanner: String? = nil

    // KataGo evaluation state
    @Published public var latestAnalysis: KataGoAnalysisResponse? = nil
    @Published public var blackWinrate: Double = 0.50
    @Published public var blackScoreLead: Double = 0.0
    @Published public var showOwnershipMap: Bool = false
    @Published public var showCandidateHints: Bool = false

    // Pause-on-blunder & variation state
    @Published public var activeIntervention: BlunderIntervention? = nil
    @Published public var variationBranches: [VariationBranch] = []
    @Published public var selectedVariationID: String? = nil
    @Published public var variationStepLimit: Int = 5

    // Coaching settings & metrics
    @Published public var blunderScoreThreshold: Double = 3.0
    @Published public var blunderWinrateThreshold: Double = 10.0
    @Published public var chatHistory: [ChatEntry] = []
    @Published public var coachModeBadge: String = "KataGo + Antigravity Ready"
    @Published public var llmCallsThisGame: Int = 0
    @Published public var estimatedTokensThisGame: Int = 0

    // Game end state
    @Published public var gameResultSummary: String? = nil

    // Game review state
    @Published public var isReviewMode: Bool = false
    @Published public var isScanningReview: Bool = false
    @Published public var reviewScanProgress: Int = 0
    @Published public var reviewScanTotal: Int = 0
    @Published public var reviewMistakes: [ReviewedMistake] = []
    @Published public var selectedReviewMistakeID: Int? = nil
    @Published public var currentReviewMoveIndex: Int = 0
    private var reviewBoards: [BoardState] = []
    private var reviewEvaluations: [Int: KataGoAnalysisResponse] = [:]
    private var reviewScanTask: Task<Void, Never>? = nil

    public let ratingManager: PlayerRatingManager
    private let katago = KataGoService()
    private let coachBridge = CoachBridgeService()
    private var undoStack: [BoardState] = []
    private var playerMoveScoreLosses: [Double] = []
    private var currentDigest: String = ""
    private var currentMeta: CoachingMeta? = nil

    public init(ratingManager: PlayerRatingManager) {
        self.ratingManager = ratingManager
        self.board = BoardState(size: 19, komi: 6.5, handicap: 0)
    }

    public var selectedVariation: VariationBranch? {
        guard let id = selectedVariationID else { return nil }
        return variationBranches.first(where: { $0.id == id })
    }

    public var selectedReviewMistake: ReviewedMistake? {
        guard let id = selectedReviewMistakeID else { return nil }
        return reviewMistakes.first(where: { $0.id == id })
    }

    public func startNewGame(size: Int, humanColor: StoneColor, handicap: Int) {
        let komi = handicap >= 2 ? 0.5 : 6.5
        let newBoard = BoardState(size: size, komi: komi, handicap: handicap)
        startGame(
            with: newBoard,
            humanColor: humanColor,
            welcomeMessage: "New \(size)×\(size) game started! You are playing \(humanColor.displayName) against a calibrated \(ratingManager.currentRank.label) human-like opponent. Play naturally—I'll pause the game before the opponent replies if I spot an important mistake."
        )
    }

    public func startGameFromBoard(_ customBoard: BoardState, humanColor: StoneColor) {
        let moveLabel = customBoard.currentMoveNumber > 0 ? " at Move #\(customBoard.currentMoveNumber)" : ""
        startGame(
            with: customBoard,
            humanColor: humanColor,
            welcomeMessage: "Loaded \(customBoard.size)×\(customBoard.size) position\(moveLabel)! You are playing \(humanColor.displayName) against a calibrated \(ratingManager.currentRank.label) human-like opponent."
        )
    }

    private func startGame(with startingBoard: BoardState, humanColor: StoneColor, welcomeMessage: String) {
        reviewScanTask?.cancel()
        reviewScanTask = nil
        isReviewMode = false
        isScanningReview = false
        reviewMistakes = []
        selectedReviewMistakeID = nil
        reviewBoards = []
        reviewEvaluations = [:]

        self.humanColor = humanColor
        self.board = startingBoard
        self.undoStack = []
        self.playerMoveScoreLosses = []
        self.activeIntervention = nil
        self.variationBranches = []
        self.selectedVariationID = nil
        self.gameResultSummary = nil
        self.errorBanner = nil
        self.blackWinrate = 0.50
        self.blackScoreLead = 0.0
        self.llmCallsThisGame = 0
        self.estimatedTokensThisGame = 0
        self.chatHistory = [
            ChatEntry(
                role: "coach",
                text: welcomeMessage,
                moveNumber: startingBoard.currentMoveNumber
            )
        ]

        Task {
            if board.nextToPlay != humanColor {
                await playOpponentTurn()
            } else {
                statusText = "Your turn (\(humanColor.displayName))"
                await refreshPositionAnalysis()
            }
        }
    }

    /// Handles a human click on an intersection (or exits variation preview if active)
    public func handleBoardIntersectionClick(_ point: BoardPoint) {
        if selectedVariationID != nil {
            selectedVariationID = nil
            return
        }
        guard !isReviewMode else { return }
        guard activeIntervention == nil else {
            errorBanner = "Choose 'Take Back & Try Again' or 'Keep Playing' on the Coach card first."
            return
        }
        guard gameResultSummary == nil else { return }
        guard !isEngineThinking else { return }
        guard board.nextToPlay == humanColor else { return }

        playHumanMove(.place(point))
    }

    public func passHumanTurn() {
        guard activeIntervention == nil, gameResultSummary == nil, !isEngineThinking, board.nextToPlay == humanColor else {
            return
        }
        playHumanMove(.pass)
    }

    private func playHumanMove(_ action: MoveAction) {
        errorBanner = nil
        selectedVariationID = nil
        let boardBefore = board

        do {
            var nextBoard = board
            let recMove = try nextBoard.play(action, color: humanColor)
            undoStack.append(boardBefore)
            board = nextBoard

            if !recMove.capturedPoints.isEmpty {
                SoundManager.shared.playCapture()
            } else {
                SoundManager.shared.playStoneClick()
            }

            if board.isGameOverByPasses {
                Task { await finishGameByScoring() }
                return
            }

            Task {
                await evaluateHumanMoveAndProceed(
                    boardBefore: boardBefore,
                    playedMove: recMove
                )
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func evaluateHumanMoveAndProceed(
        boardBefore: BoardState,
        playedMove: RecordedMove
    ) async {
        isEngineThinking = true
        statusText = "KataGo evaluating move..."

        let profile = ratingManager.currentRank.kataGoHumanSLProfile
        do {
            // 1. Ensure we have pre-move evaluation
            let preEval: KataGoAnalysisResponse
            if let existing = latestAnalysis {
                preEval = existing
            } else {
                preEval = try await katago.analyze(board: boardBefore, humanSLProfile: profile, maxVisits: 40)
            }

            // 2. Run post-move evaluation
            let postEval = try await katago.analyze(board: board, humanSLProfile: profile, maxVisits: 45)
            self.latestAnalysis = postEval
            self.blackWinrate = postEval.rootInfo.winrate
            self.blackScoreLead = postEval.rootInfo.scoreLead

            // Calculate loss from the human player's perspective
            let sign: Double = (humanColor == .black) ? 1.0 : -1.0
            let bestPreScore = (preEval.moveInfos.first?.scoreLead ?? preEval.rootInfo.scoreLead) * sign
            let afterScore = postEval.rootInfo.scoreLead * sign
            let rawScoreLoss = max(0.0, bestPreScore - afterScore)

            let bestPreWinrate = (humanColor == .black)
                ? (preEval.moveInfos.first?.winrate ?? preEval.rootInfo.winrate)
                : (1.0 - (preEval.moveInfos.first?.winrate ?? preEval.rootInfo.winrate))
            let afterWinrate = (humanColor == .black)
                ? postEval.rootInfo.winrate
                : (1.0 - postEval.rootInfo.winrate)
            let rawWinrateDropPct = max(0.0, (bestPreWinrate - afterWinrate) * 100.0)

            board.updateLastMoveEvaluation(
                blackWinrate: postEval.rootInfo.winrate,
                blackScoreLead: postEval.rootInfo.scoreLead,
                scoreLoss: rawScoreLoss,
                winrateDropPercent: rawWinrateDropPct
            )

            // Only record accuracy on non-pass moves when game isn't already 99% decided
            if playedMove.action != .pass && bestPreWinrate > 0.03 && bestPreWinrate < 0.97 {
                playerMoveScoreLosses.append(rawScoreLoss)
            }

            let playedGTP = playedMove.action.toGTP(boardSize: board.size)
            let bestGTP = preEval.moveInfos.first?.move ?? playedGTP
            let isSameAsBest = (playedGTP.uppercased() == bestGTP.uppercased())

            let isMistake = !isSameAsBest &&
                playedMove.action != .pass &&
                (rawScoreLoss >= blunderScoreThreshold || rawWinrateDropPct >= blunderWinrateThreshold)

            if isMistake {
                // PAUSE IMMEDIATELY BEFORE OPPONENT REPLIES
                isEngineThinking = false
                let severity = (rawScoreLoss >= 6.0 || rawWinrateDropPct >= 18.0) ? "blunder" : "mistake"
                let intervention = BlunderIntervention(
                    moveNumber: playedMove.moveNumber,
                    playedMoveGTP: playedGTP,
                    bestMoveGTP: bestGTP,
                    scoreLoss: rawScoreLoss,
                    winrateDropPercent: rawWinrateDropPct,
                    severityLabel: severity,
                    boardBeforeMove: boardBefore,
                    preAnalysis: preEval,
                    postAnalysis: postEval
                )
                self.activeIntervention = intervention
                self.variationBranches = buildVariationBranches(
                    boardBefore: boardBefore,
                    mover: humanColor,
                    playedMove: playedMove,
                    preEval: preEval,
                    postEval: postEval
                )
                // Auto-select the recommended variation so the user immediately sees it on the board
                self.selectedVariationID = self.variationBranches.first?.id
                self.variationStepLimit = min(5, self.variationBranches.first?.steps.count ?? 5)
                self.statusText = "Coach paused game — review \(playedGTP) vs \(bestGTP)"
                SoundManager.shared.playCoachIntervention()

                await triggerCoachingForIntervention(intervention, playedMove: playedMove)
            } else {
                // Move was good! Zero LLM tokens spent.
                ratingManager.localMovesFilteredCount += 1
                await playOpponentTurn(usingPrecomputedAnalysis: postEval)
            }
        } catch {
            isEngineThinking = false
            statusText = "Your turn"
            errorBanner = "Analysis error: \(error.localizedDescription)"
        }
    }

    /// Action 1 when paused on a blunder: Take back the stone and try again!
    public func takeBackAndRetry() {
        guard let intervention = activeIntervention else { return }
        board = intervention.boardBeforeMove
        latestAnalysis = intervention.preAnalysis
        blackWinrate = intervention.preAnalysis.rootInfo.winrate
        blackScoreLead = intervention.preAnalysis.rootInfo.scoreLead
        if !playerMoveScoreLosses.isEmpty {
            playerMoveScoreLosses.removeLast()
        }
        activeIntervention = nil
        selectedVariationID = nil
        statusText = "Move taken back — try playing a better spot!"
        SoundManager.shared.playStoneClick()
    }

    /// Action 2 when paused on a blunder: Keep the played move and let opponent reply
    public func keepPlayingAfterBlunder() {
        guard let intervention = activeIntervention else { return }
        let postAnalysis = intervention.postAnalysis
        activeIntervention = nil
        selectedVariationID = nil
        variationBranches = []
        Task {
            await playOpponentTurn(usingPrecomputedAnalysis: postAnalysis)
        }
    }

    /// Plays the opponent's human-like move using KataGo's Human SL policy
    private func playOpponentTurn(usingPrecomputedAnalysis precomputed: KataGoAnalysisResponse? = nil) async {
        guard gameResultSummary == nil else { return }
        isEngineThinking = true
        let oppColor = humanColor.opponent
        let rankLabel = ratingManager.currentRank.label
        statusText = "Opponent (\(rankLabel)) thinking..."

        let profile = ratingManager.currentRank.kataGoHumanSLProfile
        do {
            let analysis: KataGoAnalysisResponse
            if let existing = precomputed {
                analysis = existing
            } else {
                analysis = try await katago.analyze(board: board, humanSLProfile: profile, maxVisits: 80)
            }

            let oppMoveAction = katago.selectHumanLikeMove(from: analysis, board: board)
            var nextBoard = board
            let rec = try nextBoard.play(oppMoveAction, color: oppColor)
            board = nextBoard

            if !rec.capturedPoints.isEmpty {
                SoundManager.shared.playCapture()
            } else {
                SoundManager.shared.playStoneClick()
            }

            if board.isGameOverByPasses {
                isEngineThinking = false
                await finishGameByScoring()
                return
            }

            // Pre-analyze the new board state for the human's turn
            let humanTurnEval = try await katago.analyze(board: board, humanSLProfile: profile, maxVisits: 45)
            self.latestAnalysis = humanTurnEval
            self.blackWinrate = humanTurnEval.rootInfo.winrate
            self.blackScoreLead = humanTurnEval.rootInfo.scoreLead
            self.board.updateLastMoveEvaluation(
                blackWinrate: humanTurnEval.rootInfo.winrate,
                blackScoreLead: humanTurnEval.rootInfo.scoreLead,
                scoreLoss: 0,
                winrateDropPercent: 0
            )

            isEngineThinking = false
            if oppMoveAction == .pass {
                statusText = "Opponent passed — your turn (Pass to end game)"
            } else {
                statusText = "Opponent played \(oppMoveAction.toGTP(boardSize: board.size)) — your turn"
            }
        } catch {
            isEngineThinking = false
            statusText = "Your turn"
            errorBanner = "Opponent engine error: \(error.localizedDescription)"
        }
    }

    public func refreshPositionAnalysis() async {
        let profile = ratingManager.currentRank.kataGoHumanSLProfile
        if let resp = try? await katago.analyze(board: board, humanSLProfile: profile, maxVisits: 40) {
            self.latestAnalysis = resp
            self.blackWinrate = resp.rootInfo.winrate
            self.blackScoreLead = resp.rootInfo.scoreLead
        }
    }

    /// Triggered automatically when a blunder occurs
    private func triggerCoachingForIntervention(
        _ intervention: BlunderIntervention,
        playedMove: RecordedMove
    ) async {
        let bestInfo = intervention.preAnalysis.moveInfos.first
        let secondInfo = intervention.preAnalysis.moveInfos.dropFirst().first
        let oppPunishPV = intervention.postAnalysis.moveInfos.first?.pv ?? []
        let punishPV = [intervention.playedMoveGTP] + oppPunishPV

        // Run a fast follow-up query after `bestMoveGTP` so the opponent's reply is at the root node.
        // This reveals the opponent's #1 likely human reply (from `humanPolicy`) and how `bestMoveGTP`
        // refutes it, even when superhuman KataGo's main PV tenukis to dodge the trap!
        var effectiveBestPV: [String] = bestInfo?.pv ?? []
        var humanReplyRefutationLine: String? = nil
        let profile = ratingManager.currentRank.kataGoHumanSLProfile
        if let bestPt = BoardPoint.fromGTP(intervention.bestMoveGTP, boardSize: board.size) {
            var boardAfterBest = intervention.boardBeforeMove
            if (try? boardAfterBest.play(.place(bestPt), color: humanColor)) != nil,
               let afterBestEval = try? await katago.analyze(board: boardAfterBest, humanSLProfile: profile, maxVisits: 50) {
                if let (topHumanMove, topHumanProb) = afterBestEval.topHumanPolicyMove(board: boardAfterBest),
                   topHumanProb >= 0.12,
                   let humanReplyInfo = afterBestEval.moveInfos.first(where: { $0.move.uppercased() == topHumanMove.uppercased() }) {
                    let fullHumanReplyPV = [intervention.bestMoveGTP] + humanReplyInfo.pv
                    let origSecondMove = bestInfo?.pv.dropFirst().first?.uppercased()
                    if humanReplyInfo.pv.count >= 3 {
                        effectiveBestPV = fullHumanReplyPV
                    }
                    var refDesc = String(
                        format: "If opponent plays natural human reply %@ (%.0f%% human prior): continuation is %@ (Score: %+.1f B, Winrate: %.0f%%)",
                        humanReplyInfo.move,
                        topHumanProb * 100.0,
                        fullHumanReplyPV.prefix(8).joined(separator: " -> "),
                        humanReplyInfo.scoreLead,
                        humanReplyInfo.winrate * 100.0
                    )
                    if let origReply = origSecondMove, origReply != topHumanMove.uppercased() {
                        refDesc += " — superhuman AI sometimes tenukis at \(origReply) only because answering locally at \(humanReplyInfo.move) falls into this continuation"
                    }
                    humanReplyRefutationLine = refDesc
                }
            }
        }

        let tags = board.analyzeTacticalTags(
            played: playedMove.action,
            bestMoveGTP: intervention.bestMoveGTP,
            bestSecondGTP: effectiveBestPV.dropFirst().first,
            punishFirstGTP: oppPunishPV.first,
            mover: humanColor,
            boardBeforeMove: intervention.boardBeforeMove
        )

        let ownershipShifts = board.analyzeOwnershipShifts(
            preOwnership: intervention.preAnalysis.ownership,
            postOwnership: intervention.postAnalysis.ownership,
            mover: humanColor,
            boardBeforeMove: intervention.boardBeforeMove,
            playedMove: playedMove.action,
            bestMoveGTP: intervention.bestMoveGTP
        )

        let pvOutcomes = BoardState.summarizePVOutcomes(
            baseBoard: intervention.boardBeforeMove,
            mover: humanColor,
            bestPV: effectiveBestPV,
            punishPV: punishPV
        )

        let digest = board.buildCompactTacticalDigest(
            playerRank: ratingManager.currentRank.label,
            playedMove: playedMove,
            bestMoveInfo: bestInfo,
            secondMoveInfo: secondInfo,
            punishmentPV: punishPV,
            scoreLoss: intervention.scoreLoss,
            winrateDropPercent: intervention.winrateDropPercent,
            scoreLeadAfter: intervention.postAnalysis.rootInfo.scoreLead,
            tacticalTags: tags,
            ownershipShifts: ownershipShifts,
            pvOutcomes: pvOutcomes,
            humanReplyRefutationLine: humanReplyRefutationLine,
            effectiveBestPV: effectiveBestPV
        )

        let playedHumanProb = intervention.preAnalysis.humanProbability(
            forGTP: intervention.playedMoveGTP,
            boardSize: board.size
        )
        let bestHumanProb = intervention.preAnalysis.humanProbability(
            forGTP: intervention.bestMoveGTP,
            boardSize: board.size
        )

        let meta = CoachingMeta(
            playedMove: intervention.playedMoveGTP,
            bestMove: intervention.bestMoveGTP,
            secondMove: secondInfo?.move,
            scoreLoss: intervention.scoreLoss,
            winrateDropPercent: intervention.winrateDropPercent,
            scoreLeadAfter: intervention.postAnalysis.rootInfo.scoreLead,
            phase: board.gamePhase,
            tacticalTags: tags,
            ownershipShifts: ownershipShifts,
            pvOutcomes: pvOutcomes,
            bestPV: effectiveBestPV,
            punishPV: punishPV,
            playedHumanProb: playedHumanProb,
            bestHumanProb: bestHumanProb,
            playerRank: ratingManager.currentRank.label,
            severity: intervention.severityLabel
        )

        self.currentDigest = digest
        self.currentMeta = meta
        await streamCoachRequest(type: "advice", digest: digest, question: nil, meta: meta, resetSession: true)
    }

    /// On-demand "Ask Coach" button or follow-up question in chat
    public func askCoachOnDemand(question: String? = nil) async {
        let trimmedQ = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = trimmedQ, !q.isEmpty {
            chatHistory.append(ChatEntry(role: "student", text: q, moveNumber: board.moveHistory.count))
        }

        let profile = ratingManager.currentRank.kataGoHumanSLProfile
        let analysis: KataGoAnalysisResponse
        if let existing = latestAnalysis {
            analysis = existing
        } else if let fresh = try? await katago.analyze(board: board, humanSLProfile: profile, maxVisits: 90) {
            self.latestAnalysis = fresh
            analysis = fresh
        } else {
            return
        }

        // Build variation branches for the current position if none are active
        if variationBranches.isEmpty {
            variationBranches = buildCurrentPositionVariations(board: board, analysis: analysis)
        }

        // If the student asked a specific question mentioning board coordinates, run live
        // counterfactual KataGo verification so the coach has exact MCTS facts for those coordinates!
        var counterfactualNotes: [String] = []
        if let q = trimmedQ, !q.isEmpty {
            counterfactualNotes = await runCounterfactualVerification(question: q, profile: profile, fallbackAnalysis: analysis)
        }

        let bestInfo = (activeIntervention?.preAnalysis ?? analysis).moveInfos.first
        let secondInfo = (activeIntervention?.preAnalysis ?? analysis).moveInfos.dropFirst().first
        let baseDigest = currentDigest.isEmpty ? board.buildCompactTacticalDigest(
            playerRank: ratingManager.currentRank.label,
            playedMove: board.moveHistory.last,
            bestMoveInfo: bestInfo,
            secondMoveInfo: secondInfo,
            punishmentPV: [],
            scoreLoss: activeIntervention?.scoreLoss ?? 0.0,
            winrateDropPercent: activeIntervention?.winrateDropPercent ?? 0.0,
            scoreLeadAfter: analysis.rootInfo.scoreLead,
            tacticalTags: [],
            counterfactualNotes: counterfactualNotes
        ) : (counterfactualNotes.isEmpty ? currentDigest : "\(currentDigest)\n[KataGo Counterfactual Verification for Student's Question]\n\(counterfactualNotes.joined(separator: "\n"))")

        let baseMeta = currentMeta
        let meta = CoachingMeta(
            playedMove: baseMeta?.playedMove ?? "none",
            bestMove: baseMeta?.bestMove ?? (bestInfo?.move ?? "pass"),
            secondMove: baseMeta?.secondMove ?? secondInfo?.move,
            scoreLoss: baseMeta?.scoreLoss ?? 0.0,
            winrateDropPercent: baseMeta?.winrateDropPercent ?? 0.0,
            scoreLeadAfter: baseMeta?.scoreLeadAfter ?? analysis.rootInfo.scoreLead,
            phase: baseMeta?.phase ?? board.gamePhase,
            tacticalTags: baseMeta?.tacticalTags ?? [],
            ownershipShifts: baseMeta?.ownershipShifts ?? [],
            pvOutcomes: baseMeta?.pvOutcomes ?? [],
            counterfactualNotes: counterfactualNotes,
            bestPV: baseMeta?.bestPV ?? (bestInfo?.pv ?? []),
            punishPV: baseMeta?.punishPV ?? [],
            playedHumanProb: baseMeta?.playedHumanProb,
            bestHumanProb: baseMeta?.bestHumanProb,
            playerRank: ratingManager.currentRank.label,
            severity: baseMeta?.severity ?? "info"
        )

        let reqType = (trimmedQ != nil && !(trimmedQ!.isEmpty)) ? "followup" : "advice"
        await streamCoachRequest(
            type: reqType,
            digest: baseDigest,
            question: trimmedQ,
            meta: meta,
            resetSession: reqType == "advice"
        )
    }

    /// Runs live 40-visit KataGo counterfactual queries on any coordinates mentioned in the student's question.
    private func runCounterfactualVerification(
        question: String,
        profile: String,
        fallbackAnalysis: KataGoAnalysisResponse
    ) async -> [String] {
        let refBoard = activeIntervention?.boardBeforeMove ?? board
        let refAnalysis = activeIntervention?.preAnalysis ?? fallbackAnalysis
        let coords = BoardState.extractMentionedCoordinates(from: question, boardSize: refBoard.size)
        guard !coords.isEmpty else { return [] }

        var notes: [String] = []
        let mover = humanColor
        let sign: Double = (mover == .black) ? 1.0 : -1.0
        let bestRefScore = (refAnalysis.moveInfos.first?.scoreLead ?? refAnalysis.rootInfo.scoreLead) * sign

        for pt in coords {
            let gtp = pt.toGTP(boardSize: refBoard.size)

            // Case 1: Coordinate is an empty legal move on `refBoard` — play it and query KataGo!
            if refBoard.stone(at: pt) == nil, case .success = refBoard.canPlay(at: pt, color: mover) {
                var hypoBoard = refBoard
                guard (try? hypoBoard.play(.place(pt), color: mover)) != nil else { continue }
                guard let hypoEval = try? await katago.analyze(board: hypoBoard, humanSLProfile: profile, maxVisits: 40) else {
                    continue
                }

                let scoreAfterHypo = hypoEval.rootInfo.scoreLead * sign
                let deltaVsBest = scoreAfterHypo - bestRefScore
                let oppReplyPV = hypoEval.moveInfos.first?.pv ?? []
                let combinedPV = [gtp] + Array(oppReplyPV.prefix(5))
                let (_, libsAfterHypo) = hypoBoard.groupAndLiberties(at: pt)

                var stoneSurvPct = 50
                if let own = hypoEval.ownership, own.count >= refBoard.size * refBoard.size {
                    let rawOwn = own[pt.row * refBoard.size + pt.col]
                    stoneSurvPct = Int((((rawOwn * sign) + 1.0) * 50.0).rounded())
                }

                let roleDesc: String
                if stoneSurvPct < 36 {
                    roleDesc = "sacrificial probe/kikashi (only \(stoneSurvPct)% expected end-of-game stone survival — not meant to live locally)"
                } else if stoneSurvPct >= 70 {
                    roleDesc = "high survival (\(stoneSurvPct)% expected to live/settle)"
                } else {
                    roleDesc = "unsettled/fighting stone (\(stoneSurvPct)% expected survival)"
                }

                var line = String(
                    format: "- Hypothetical move %@ (%@): Score vs best move: %+.1f pts | Stone status: %@ (%d initial liberties) | Expected continuation: %@",
                    gtp, mover.displayName, deltaVsBest, roleDesc, libsAfterHypo.count, combinedPV.joined(separator: " -> ")
                )

                // If opponent replies locally and the stone has low survival, also check what happens if student tries to rescue it!
                if stoneSurvPct < 45,
                   let oppFirstGTP = oppReplyPV.first,
                   let oppPt = BoardPoint.fromGTP(oppFirstGTP, boardSize: refBoard.size) {
                    var afterOppBoard = hypoBoard
                    if (try? afterOppBoard.play(.place(oppPt), color: mover.opponent)) != nil {
                        let (_, libsAfterOpp) = afterOppBoard.groupAndLiberties(at: pt)
                        if let afterOppEval = try? await katago.analyze(board: afterOppBoard, humanSLProfile: profile, maxVisits: 35),
                           let nextBest = afterOppEval.moveInfos.first {
                            line += String(
                                format: " | After opponent's %@, %@ has %d liberties and KataGo's top next move is %@ (rather than rescuing %@ locally)",
                                oppFirstGTP, gtp, libsAfterOpp.count, nextBest.move, gtp
                            )
                        }
                    }
                }

                notes.append(line)

                // Add a clickable variation branch on the board for this asked coordinate if not already present
                let branchID = "asked_\(gtp)"
                if !variationBranches.contains(where: { $0.id == branchID }) {
                    let steps = parsePVSteps(pv: combinedPV, startingColor: mover, boardSize: refBoard.size)
                    if !steps.isEmpty {
                        variationBranches.append(
                            VariationBranch(
                                id: branchID,
                                title: "Asked: \(gtp)",
                                subtitle: String(format: "%+.1f pts vs best (%d%% survival)", deltaVsBest, stoneSurvPct),
                                isRecommended: deltaVsBest >= -0.5,
                                baseBoard: refBoard,
                                steps: steps
                            )
                        )
                    }
                }
            }
            // Case 2: Coordinate already has a stone on `board` — report its current liberties and survival
            else if let stColor = board.stone(at: pt) {
                let (grp, libs) = board.groupAndLiberties(at: pt)
                let stSign: Double = (stColor == .black) ? 1.0 : -1.0
                var survPct = 50
                if let own = fallbackAnalysis.ownership, own.count >= board.size * board.size {
                    let rawOwn = own[pt.row * board.size + pt.col]
                    survPct = Int((((rawOwn * stSign) + 1.0) * 50.0).rounded())
                }
                notes.append(
                    String(
                        format: "- Existing %@ group at %@ (%d stones): currently has %d liberties and %d%% expected survival in KataGo's ownership map",
                        stColor.displayName, gtp, grp.count, libs.count, survPct
                    )
                )
            }
        }

        return notes
    }

    private func streamCoachRequest(
        type: String,
        digest: String,
        question: String?,
        meta: CoachingMeta,
        resetSession: Bool
    ) async {
        isCoachStreaming = true
        let entryID = UUID()
        let moveNum = board.moveHistory.count
        chatHistory.append(ChatEntry(id: entryID, role: "coach", text: "", moveNumber: moveNum))

        // Estimate compact token count (~4 chars per token)
        let tokenEst = max(80, (digest.count + (question?.count ?? 0)) / 4)
        llmCallsThisGame += 1
        estimatedTokensThisGame += tokenEst

        do {
            let (finalText, source) = try await coachBridge.requestCoaching(
                type: type,
                digest: digest,
                question: question,
                meta: meta,
                resetSession: resetSession
            ) { [weak self] delta in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let idx = self.chatHistory.firstIndex(where: { $0.id == entryID }) {
                        self.chatHistory[idx].text += delta
                    }
                }
            }

            if let idx = chatHistory.firstIndex(where: { $0.id == entryID }) {
                let badge: String
                switch source {
                case "antigravity_ipc": badge = "Antigravity Live Session"
                case "antigravity_sdk": badge = "Antigravity SDK"
                default: badge = "KataGo + Human-SL Coach"
                }
                coachModeBadge = badge
                chatHistory[idx] = ChatEntry(
                    id: entryID,
                    role: "coach",
                    text: finalText.isEmpty ? chatHistory[idx].text : finalText,
                    moveNumber: moveNum,
                    sourceBadge: badge
                )
            }
        } catch {
            if let idx = chatHistory.firstIndex(where: { $0.id == entryID }) {
                chatHistory[idx].text = "Coach note: \(meta.bestMove) is the recommended move here (saves \(String(format: "%.1f", meta.scoreLoss)) pts)."
            }
        }
        isCoachStreaming = false
    }

    /// Builds clickable variation branches on the board when a blunder is detected
    private func buildVariationBranches(
        boardBefore: BoardState,
        mover: StoneColor,
        playedMove: RecordedMove,
        preEval: KataGoAnalysisResponse,
        postEval: KataGoAnalysisResponse
    ) -> [VariationBranch] {
        var branches: [VariationBranch] = []
        let size = boardBefore.size

        // 1. Best variation from KataGo
        if let best = preEval.moveInfos.first {
            let steps = parsePVSteps(pv: best.pv, startingColor: mover, boardSize: size)
            if !steps.isEmpty {
                branches.append(
                    VariationBranch(
                        id: "best",
                        title: "Recommended: \(best.move)",
                        subtitle: String(format: "Saves %.1f pts (%+.0f%% winrate)", max(0.1, playedMove.scoreLoss ?? 0), max(1, playedMove.winrateDropPercent ?? 0)),
                        isRecommended: true,
                        baseBoard: boardBefore,
                        steps: steps
                    )
                )
            }
        }

        // 2. Second option if within 2.5 points of best
        if preEval.moveInfos.count >= 2 {
            let second = preEval.moveInfos[1]
            let playedGTP = playedMove.action.toGTP(boardSize: size)
            if second.move.uppercased() != playedGTP.uppercased() {
                let steps = parsePVSteps(pv: second.pv, startingColor: mover, boardSize: size)
                if !steps.isEmpty {
                    branches.append(
                        VariationBranch(
                            id: "alt",
                            title: "Alternative: \(second.move)",
                            subtitle: "Playable 2nd choice",
                            isRecommended: false,
                            baseBoard: boardBefore,
                            steps: steps
                        )
                    )
                }
            }
        }

        // 3. Punishment PV after the player's actual move
        if let oppBest = postEval.moveInfos.first {
            let playedGTP = playedMove.action.toGTP(boardSize: size)
            let combinedPV = [playedGTP] + Array(oppBest.pv.prefix(5))
            let steps = parsePVSteps(pv: combinedPV, startingColor: mover, boardSize: size)
            if !steps.isEmpty {
                branches.append(
                    VariationBranch(
                        id: "punish",
                        title: "Your Move: \(playedGTP)",
                        subtitle: "How opponent punishes (\(oppBest.move))",
                        isRecommended: false,
                        baseBoard: boardBefore,
                        steps: steps
                    )
                )
            }
        }

        return branches
    }

    private func buildCurrentPositionVariations(
        board: BoardState,
        analysis: KataGoAnalysisResponse
    ) -> [VariationBranch] {
        var branches: [VariationBranch] = []
        for (idx, info) in analysis.moveInfos.prefix(2).enumerated() {
            let steps = parsePVSteps(pv: info.pv, startingColor: board.nextToPlay, boardSize: board.size)
            guard !steps.isEmpty else { continue }
            branches.append(
                VariationBranch(
                    id: "pos_\(idx)",
                    title: idx == 0 ? "Best Line: \(info.move)" : "Option B: \(info.move)",
                    subtitle: String(format: "Winrate %.0f%%", (board.nextToPlay == .black ? info.winrate : 1.0 - info.winrate) * 100),
                    isRecommended: idx == 0,
                    baseBoard: board,
                    steps: steps
                )
            )
        }
        return branches
    }

    private func parsePVSteps(pv: [String], startingColor: StoneColor, boardSize: Int) -> [VariationStep] {
        var steps: [VariationStep] = []
        var color = startingColor
        for (i, gtp) in pv.prefix(6).enumerated() {
            if let pt = BoardPoint.fromGTP(gtp, boardSize: boardSize) {
                steps.append(VariationStep(stepNumber: i + 1, color: color, point: pt, gtp: gtp))
            }
            color = color.opponent
        }
        return steps
    }

    public func undoLastExchange() {
        guard activeIntervention == nil else {
            takeBackAndRetry()
            return
        }
        guard let prev = undoStack.popLast() else { return }
        board = prev
        selectedVariationID = nil
        variationBranches = []
        gameResultSummary = nil
        statusText = "Move undone — your turn"
        Task { await refreshPositionAnalysis() }
    }

    public func resignGame() {
        guard gameResultSummary == nil else { return }
        let winner = humanColor.opponent.displayName
        gameResultSummary = "\(winner) wins by Resignation"
        statusText = gameResultSummary!
        ratingManager.recordGamePerformance(playerWon: false, playerMoveScoreLosses: playerMoveScoreLosses)
    }

    private func finishGameByScoring() async {
        let profile = ratingManager.currentRank.kataGoHumanSLProfile
        if let finalEval = try? await katago.analyze(board: board, humanSLProfile: profile, maxVisits: 150, includeOwnership: true) {
            self.latestAnalysis = finalEval
            self.blackWinrate = finalEval.rootInfo.winrate
            self.blackScoreLead = finalEval.rootInfo.scoreLead
        }

        let lead = blackScoreLead
        let blackWins = lead >= 0
        let margin = String(format: "%.1f", abs(lead))
        let winnerName = blackWins ? "Black" : "White"
        let playerWon = (humanColor == .black && blackWins) || (humanColor == .white && !blackWins)

        gameResultSummary = "Game Over — \(winnerName) wins by \(margin) points"
        statusText = gameResultSummary!
        showOwnershipMap = true
        ratingManager.recordGamePerformance(playerWon: playerWon, playerMoveScoreLosses: playerMoveScoreLosses)
    }

    public func copySGFToClipboard() {
        let sgf = board.toSGF(
            playerBlackName: humanColor == .black ? "Student (\(ratingManager.currentRank.label))" : "KataGo (\(ratingManager.currentRank.label))",
            playerWhiteName: humanColor == .white ? "Student (\(ratingManager.currentRank.label))" : "KataGo (\(ratingManager.currentRank.label))"
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sgf, forType: .string)
        statusText = "SGF copied to clipboard!"
    }

    // MARK: - Game Review Mode

    public func startGameReview(fullBoard: BoardState, reviewColor: StoneColor?) {
        reviewScanTask?.cancel()
        reviewScanTask = nil

        var boardsByPly: [BoardState] = []
        var cursor = BoardState(
            size: fullBoard.size,
            komi: fullBoard.komi,
            initialStones: fullBoard.initialStones,
            initialPlayer: fullBoard.initialPlayer,
            initialMoveNumber: fullBoard.initialMoveNumber
        )
        boardsByPly.append(cursor)
        for rec in fullBoard.moveHistory {
            _ = try? cursor.play(rec.action, color: rec.color)
            boardsByPly.append(cursor)
        }

        let totalMoves = fullBoard.moveHistory.count
        self.isReviewMode = true
        self.isScanningReview = totalMoves > 0
        self.reviewScanProgress = 0
        self.reviewScanTotal = totalMoves
        self.reviewMistakes = []
        self.selectedReviewMistakeID = nil
        self.reviewBoards = boardsByPly
        self.reviewEvaluations = [:]
        self.currentReviewMoveIndex = totalMoves
        self.board = fullBoard
        self.undoStack = []
        self.activeIntervention = nil
        self.variationBranches = []
        self.selectedVariationID = nil
        self.gameResultSummary = nil
        self.errorBanner = nil

        if let side = reviewColor {
            self.humanColor = side
        }

        let targetLabel = reviewColor?.displayName ?? "Black & White"
        self.chatHistory = [
            ChatEntry(
                role: "coach",
                text: "Scanning \(totalMoves) moves with KataGo to find major mistakes (\(targetLabel), threshold ≥ \(String(format: "%.1f", blunderScoreThreshold)) pts). Click any mistake in the list as it appears to see the variations and get a coaching explanation!",
                moveNumber: 0
            )
        ]

        let profile = ratingManager.currentRank.kataGoHumanSLProfile
        reviewScanTask = Task { [weak self] in
            guard let self = self else { return }
            var prevEval: KataGoAnalysisResponse? = nil

            for ply in 0...totalMoves {
                if Task.isCancelled { break }
                let plyBoard = self.reviewBoards[ply]
                guard let eval = try? await self.katago.analyze(
                    board: plyBoard,
                    humanSLProfile: profile,
                    maxVisits: 25,
                    includeOwnership: true
                ) else {
                    continue
                }
                if Task.isCancelled { break }

                self.reviewEvaluations[ply] = eval
                self.reviewScanProgress = ply
                self.statusText = ply < totalMoves
                    ? "Reviewing game: Move \(ply) / \(totalMoves)..."
                    : "Review complete — \(self.reviewMistakes.count) major mistakes found"

                if ply > 0, let pre = prevEval {
                    let playedMove = plyBoard.moveHistory[ply - 1]
                    let mover = playedMove.color
                    let sign: Double = (mover == .black) ? 1.0 : -1.0

                    let bestPreLead = pre.moveInfos.first?.scoreLead ?? pre.rootInfo.scoreLead
                    let bestPreWinrate = pre.moveInfos.first?.winrate ?? pre.rootInfo.winrate
                    let postLead = eval.rootInfo.scoreLead
                    let postWinrate = eval.rootInfo.winrate

                    let rawScoreLoss = (bestPreLead - postLead) * sign
                    let rawWinrateDrop = (bestPreWinrate - postWinrate) * sign * 100.0
                    let bestMoveGTP = pre.moveInfos.first?.move ?? "pass"
                    let playedGTP = playedMove.action.toGTP(boardSize: plyBoard.size)
                    let isTopMove = (playedGTP.uppercased() == bestMoveGTP.uppercased())
                    let scoreLoss = isTopMove ? 0.0 : max(0.0, rawScoreLoss)
                    let winrateDrop = isTopMove ? 0.0 : max(0.0, rawWinrateDrop)

                    // Update board move history so the winrate sparkline updates live
                    self.board.updateMoveEvaluation(
                        atIndex: ply - 1,
                        blackWinrateAfter: postWinrate,
                        blackScoreLeadAfter: postLead,
                        scoreLoss: scoreLoss,
                        winrateDropPercent: winrateDrop
                    )
                    if ply < self.reviewBoards.count {
                        for idx in ply..<self.reviewBoards.count {
                            self.reviewBoards[idx].updateMoveEvaluation(
                                atIndex: ply - 1,
                                blackWinrateAfter: postWinrate,
                                blackScoreLeadAfter: postLead,
                                scoreLoss: scoreLoss,
                                winrateDropPercent: winrateDrop
                            )
                        }
                    }

                    let matchesSide = (reviewColor == nil || reviewColor == mover)
                    let isMistake = matchesSide && !isTopMove &&
                        (scoreLoss >= self.blunderScoreThreshold || winrateDrop >= self.blunderWinrateThreshold)

                    if isMistake {
                        let severity: String
                        if scoreLoss >= 8.0 || winrateDrop >= 20.0 {
                            severity = "major_blunder"
                        } else if scoreLoss >= 4.5 || winrateDrop >= 12.0 {
                            severity = "blunder"
                        } else {
                            severity = "mistake"
                        }

                        var updatedMove = playedMove
                        updatedMove.blackWinrateAfter = postWinrate
                        updatedMove.blackScoreLeadAfter = postLead
                        updatedMove.scoreLoss = scoreLoss
                        updatedMove.winrateDropPercent = winrateDrop

                        let mistake = ReviewedMistake(
                            moveNumber: playedMove.moveNumber,
                            color: mover,
                            playedMove: updatedMove,
                            playedMoveGTP: playedGTP,
                            bestMoveGTP: bestMoveGTP,
                            scoreLoss: scoreLoss,
                            winrateDropPercent: winrateDrop,
                            severityLabel: severity,
                            boardBeforeMove: self.reviewBoards[ply - 1],
                            boardAfterMove: self.reviewBoards[ply],
                            preAnalysis: pre,
                            postAnalysis: eval
                        )
                        self.reviewMistakes.append(mistake)
                    }
                }

                prevEval = eval
            }

            self.isScanningReview = false
            if !Task.isCancelled {
                self.statusText = "Review complete — \(self.reviewMistakes.count) major mistake\(self.reviewMistakes.count == 1 ? "" : "s") found"
            }
        }
    }

    public func stopReviewScan() {
        reviewScanTask?.cancel()
        reviewScanTask = nil
        isScanningReview = false
        statusText = "Review scan paused — \(reviewMistakes.count) mistake\(reviewMistakes.count == 1 ? "" : "s") found"
    }

    public func stepReviewMove(to index: Int) {
        guard isReviewMode, !reviewBoards.isEmpty else { return }
        let clamped = max(0, min(reviewBoards.count - 1, index))
        currentReviewMoveIndex = clamped
        selectedVariationID = nil
        board = reviewBoards[clamped]

        if let eval = reviewEvaluations[clamped] {
            latestAnalysis = eval
            blackWinrate = eval.rootInfo.winrate
            blackScoreLead = eval.rootInfo.scoreLead
        }

        if let matchingMistake = reviewMistakes.first(where: { $0.moveNumber == board.currentMoveNumber }) {
            selectedReviewMistakeID = matchingMistake.id
            variationBranches = buildVariationBranches(
                boardBefore: matchingMistake.boardBeforeMove,
                mover: matchingMistake.color,
                playedMove: matchingMistake.playedMove,
                preEval: matchingMistake.preAnalysis,
                postEval: matchingMistake.postAnalysis
            )
        } else {
            selectedReviewMistakeID = nil
            variationBranches = []
        }

        statusText = "Reviewing Move #\(board.currentMoveNumber) of \(reviewBoards.count - 1)"
    }

    public func resumePlayingFromReviewPosition() {
        guard isReviewMode else { return }
        let targetBoard = board
        let playColor = targetBoard.nextToPlay
        startGameFromBoard(targetBoard, humanColor: playColor)
    }

    public func selectReviewedMistake(_ mistake: ReviewedMistake) {
        selectedVariationID = nil
        selectedReviewMistakeID = mistake.id
        if let plyIndex = reviewBoards.firstIndex(where: { $0.currentMoveNumber == mistake.moveNumber }) {
            currentReviewMoveIndex = plyIndex
            board = reviewBoards[plyIndex]
        } else {
            board = mistake.boardAfterMove
        }

        humanColor = mistake.color
        latestAnalysis = mistake.postAnalysis
        blackWinrate = mistake.postAnalysis.rootInfo.winrate
        blackScoreLead = mistake.postAnalysis.rootInfo.scoreLead
        statusText = "Reviewing Move #\(mistake.moveNumber): \(mistake.color.displayName) \(mistake.playedMoveGTP) (Best: \(mistake.bestMoveGTP))"

        variationBranches = buildVariationBranches(
            boardBefore: mistake.boardBeforeMove,
            mover: mistake.color,
            playedMove: mistake.playedMove,
            preEval: mistake.preAnalysis,
            postEval: mistake.postAnalysis
        )

        if let cached = mistake.explanation, !cached.isEmpty {
            if !chatHistory.contains(where: { $0.moveNumber == mistake.moveNumber && $0.text == cached }) {
                chatHistory.append(
                    ChatEntry(
                        role: "coach",
                        text: cached,
                        moveNumber: mistake.moveNumber,
                        sourceBadge: mistake.explanationSourceBadge
                    )
                )
            }
            return
        }

        Task {
            await explainReviewedMistake(mistake)
        }
    }

    private func explainReviewedMistake(_ mistake: ReviewedMistake) async {
        let profile = ratingManager.currentRank.kataGoHumanSLProfile
        var preEval = mistake.preAnalysis
        let postEval = mistake.postAnalysis

        // Upgrade `preEval` to full 200-visit depth so tactical PVs are super sharp
        if let deepPre = try? await katago.analyze(
            board: mistake.boardBeforeMove,
            humanSLProfile: profile,
            maxVisits: 200,
            includeOwnership: true
        ) {
            preEval = deepPre
        }

        let bestInfo = preEval.moveInfos.first
        let secondInfo = preEval.moveInfos.dropFirst().first
        let bestMoveGTP = bestInfo?.move ?? mistake.bestMoveGTP
        let oppPunishPV = postEval.moveInfos.first?.pv ?? []
        let punishPV = [mistake.playedMoveGTP] + oppPunishPV

        // Run the 1-ply follow-up query after `bestMoveGTP` for natural human reply & refutation
        var effectiveBestPV: [String] = bestInfo?.pv ?? []
        var humanReplyRefutationLine: String? = nil
        if let bestPt = BoardPoint.fromGTP(bestMoveGTP, boardSize: mistake.boardBeforeMove.size) {
            var boardAfterBest = mistake.boardBeforeMove
            if (try? boardAfterBest.play(.place(bestPt), color: mistake.color)) != nil,
               let afterBestEval = try? await katago.analyze(board: boardAfterBest, humanSLProfile: profile, maxVisits: 50) {
                if let (topHumanMove, topHumanProb) = afterBestEval.topHumanPolicyMove(board: boardAfterBest),
                   topHumanProb >= 0.12,
                   let humanReplyInfo = afterBestEval.moveInfos.first(where: { $0.move.uppercased() == topHumanMove.uppercased() }) {
                    let fullHumanReplyPV = [bestMoveGTP] + humanReplyInfo.pv
                    let origSecondMove = bestInfo?.pv.dropFirst().first?.uppercased()
                    if humanReplyInfo.pv.count >= 3 {
                        effectiveBestPV = fullHumanReplyPV
                    }
                    var refDesc = String(
                        format: "If opponent plays natural human reply %@ (%.0f%% human prior): continuation is %@ (Score: %+.1f B, Winrate: %.0f%%)",
                        humanReplyInfo.move,
                        topHumanProb * 100.0,
                        fullHumanReplyPV.prefix(8).joined(separator: " -> "),
                        humanReplyInfo.scoreLead,
                        humanReplyInfo.winrate * 100.0
                    )
                    if let origReply = origSecondMove, origReply != topHumanMove.uppercased() {
                        refDesc += " — superhuman AI sometimes tenukis at \(origReply) only because answering locally at \(humanReplyInfo.move) falls into this continuation"
                    }
                    humanReplyRefutationLine = refDesc
                }
            }
        }

        // Update variations with the upgraded 200-visit preEval
        if let idx = reviewMistakes.firstIndex(where: { $0.id == mistake.id }) {
            reviewMistakes[idx].preAnalysis = preEval
            reviewMistakes[idx].bestMoveGTP = bestMoveGTP
        }
        if selectedReviewMistakeID == mistake.id {
            variationBranches = buildVariationBranches(
                boardBefore: mistake.boardBeforeMove,
                mover: mistake.color,
                playedMove: mistake.playedMove,
                preEval: preEval,
                postEval: postEval
            )
        }

        let tags = mistake.boardAfterMove.analyzeTacticalTags(
            played: mistake.playedMove.action,
            bestMoveGTP: bestMoveGTP,
            bestSecondGTP: effectiveBestPV.dropFirst().first,
            punishFirstGTP: oppPunishPV.first,
            mover: mistake.color,
            boardBeforeMove: mistake.boardBeforeMove
        )

        let ownershipShifts = mistake.boardAfterMove.analyzeOwnershipShifts(
            preOwnership: preEval.ownership,
            postOwnership: postEval.ownership,
            mover: mistake.color,
            boardBeforeMove: mistake.boardBeforeMove,
            playedMove: mistake.playedMove.action,
            bestMoveGTP: bestMoveGTP
        )

        let pvOutcomes = BoardState.summarizePVOutcomes(
            baseBoard: mistake.boardBeforeMove,
            mover: mistake.color,
            bestPV: effectiveBestPV,
            punishPV: punishPV
        )

        let digest = mistake.boardAfterMove.buildCompactTacticalDigest(
            playerRank: ratingManager.currentRank.label,
            playedMove: mistake.playedMove,
            bestMoveInfo: bestInfo,
            secondMoveInfo: secondInfo,
            punishmentPV: punishPV,
            scoreLoss: mistake.scoreLoss,
            winrateDropPercent: mistake.winrateDropPercent,
            scoreLeadAfter: postEval.rootInfo.scoreLead,
            tacticalTags: tags,
            ownershipShifts: ownershipShifts,
            pvOutcomes: pvOutcomes,
            humanReplyRefutationLine: humanReplyRefutationLine,
            effectiveBestPV: effectiveBestPV
        )

        let playedHumanProb = preEval.humanProbability(
            forGTP: mistake.playedMoveGTP,
            boardSize: mistake.boardBeforeMove.size
        )
        let bestHumanProb = preEval.humanProbability(
            forGTP: bestMoveGTP,
            boardSize: mistake.boardBeforeMove.size
        )

        let meta = CoachingMeta(
            playedMove: mistake.playedMoveGTP,
            bestMove: bestMoveGTP,
            secondMove: secondInfo?.move,
            scoreLoss: mistake.scoreLoss,
            winrateDropPercent: mistake.winrateDropPercent,
            scoreLeadAfter: postEval.rootInfo.scoreLead,
            phase: mistake.boardAfterMove.gamePhase,
            tacticalTags: tags,
            ownershipShifts: ownershipShifts,
            pvOutcomes: pvOutcomes,
            bestPV: effectiveBestPV,
            punishPV: punishPV,
            playedHumanProb: playedHumanProb,
            bestHumanProb: bestHumanProb,
            playerRank: ratingManager.currentRank.label,
            severity: mistake.severityLabel
        )

        self.currentDigest = digest
        self.currentMeta = meta
        await streamCoachRequest(type: "advice", digest: digest, question: nil, meta: meta, resetSession: true)

        if let lastCoach = chatHistory.last(where: { $0.role == "coach" && $0.moveNumber == mistake.moveNumber }),
           let idx = reviewMistakes.firstIndex(where: { $0.id == mistake.id }) {
            reviewMistakes[idx].explanation = lastCoach.text
            reviewMistakes[idx].explanationSourceBadge = lastCoach.sourceBadge
        }
    }
}
