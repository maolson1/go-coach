import Foundation

public struct KataGoMoveInfo: Codable, Sendable, Equatable {
    public let move: String
    public let visits: Int
    /// Winrate from Black's perspective (0.0 ... 1.0) because reportAnalysisWinratesAs = BLACK
    public let winrate: Double
    /// Score lead from Black's perspective (positive = Black ahead)
    public let scoreLead: Double
    public let prior: Double
    public let humanPrior: Double?
    public let order: Int
    public let pv: [String]
}

public struct KataGoRootInfo: Codable, Sendable, Equatable {
    public let currentPlayer: String
    /// Winrate from Black's perspective (0.0 ... 1.0)
    public let winrate: Double
    /// Score lead from Black's perspective
    public let scoreLead: Double
    public let visits: Int
}

public struct KataGoAnalysisResponse: Codable, Sendable, Equatable {
    public let id: String
    public let isDuringSearch: Bool?
    public let turnNumber: Int?
    public var moveInfos: [KataGoMoveInfo]
    public let rootInfo: KataGoRootInfo
    public let ownership: [Double]?
    public let policy: [Double]?
    public let humanPolicy: [Double]?

    /// Returns the top human-likely move (GTP coordinate and probability) from `humanPolicy`
    public func topHumanPolicyMove(board: BoardState) -> (move: String, probability: Double)? {
        let size = board.size
        guard let hp = humanPolicy, hp.count >= size * size else { return nil }
        var bestPt: BoardPoint? = nil
        var bestProb: Double = -1.0
        for r in 0..<size {
            for c in 0..<size {
                let p = hp[r * size + c]
                guard p > bestProb else { continue }
                let pt = BoardPoint(col: c, row: r)
                if case .success = board.canPlay(at: pt) {
                    bestProb = p
                    bestPt = pt
                }
            }
        }
        guard let pt = bestPt, bestProb > 0 else { return nil }
        return (pt.toGTP(boardSize: size), bestProb)
    }

    /// Returns probability of playing `gtpMove` according to the Human SL model
    public func humanProbability(forGTP gtpMove: String, boardSize: Int) -> Double? {
        if let info = moveInfos.first(where: { $0.move.uppercased() == gtpMove.uppercased() }),
           let hp = info.humanPrior, hp >= 0 {
            return hp
        }
        guard let hpArray = humanPolicy else { return nil }
        if gtpMove.lowercased() == "pass" {
            let passIdx = boardSize * boardSize
            return passIdx < hpArray.count ? max(0, hpArray[passIdx]) : nil
        }
        guard let pt = BoardPoint.fromGTP(gtpMove, boardSize: boardSize) else { return nil }
        let idx = pt.row * boardSize + pt.col
        guard idx >= 0 && idx < hpArray.count else { return nil }
        let val = hpArray[idx]
        return val >= 0 ? val : nil
    }
}

public actor KataGoService {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pendingContinuations: [String: CheckedContinuation<KataGoAnalysisResponse, Error>] = [:]
    private var readTask: Task<Void, Never>?
    public private(set) var isReady: Bool = false
    public private(set) var hasHumanSLModel: Bool = false

    public init() {}

    public func startIfNeeded() throws {
        if let proc = process, proc.isRunning {
            return
        }

        let katagoPath = Self.locateBinary()
        let configPath = "/opt/homebrew/opt/katago/share/katago/configs/analysis_example.cfg"
        let mainModelPath = Self.locateMainModel()
        let humanModelPath = Self.locateHumanModel()

        let logDir = "/tmp/gocoach_katago_logs"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: katagoPath)
        proc.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        var args = [
            "analysis",
            "-config", configPath,
            "-model", mainModelPath,
            "-override-config",
            "logDir=\(logDir),logToStderr=false,numAnalysisThreads=2,numSearchThreadsPerAnalysisThread=8,reportAnalysisWinratesAs=BLACK,maxVisits=200"
        ]

        if let humanPath = humanModelPath, FileManager.default.fileExists(atPath: humanPath) {
            args.append(contentsOf: ["-human-model", humanPath])
            hasHumanSLModel = true
        } else {
            hasHumanSLModel = false
        }

        proc.arguments = args

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self.isReady = true

        let handle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        self.readTask = Task.detached { [weak self] in
            var buffer = Data()
            let newline = UInt8(ascii: "\n")
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    let errData = errHandle.availableData
                    let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "KataGo process exited unexpectedly"
                    await self?.handleProcessEOF(errorMessage: errStr)
                    break
                }
                buffer.append(chunk)
                while let range = buffer.firstIndex(of: newline) {
                    let lineData = buffer.subdata(in: 0..<range)
                    buffer.removeSubrange(0...range)
                    if !lineData.isEmpty {
                        await self?.handleOutputLine(lineData)
                    }
                }
            }
        }
    }

    private func handleProcessEOF(errorMessage: String) {
        isReady = false
        process = nil
        let err = NSError(
            domain: "KataGoService",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: errorMessage.isEmpty ? "KataGo exited" : errorMessage]
        )
        let all = pendingContinuations
        pendingContinuations.removeAll()
        for (_, cont) in all {
            cont.resume(throwing: err)
        }
    }

    private func handleOutputLine(_ data: Data) {
        let decoder = JSONDecoder()
        guard var resp = try? decoder.decode(KataGoAnalysisResponse.self, from: data) else {
            return
        }
        if resp.isDuringSearch == true {
            return
        }
        if resp.moveInfos.count > 1 {
            let maxV = resp.moveInfos.map(\.visits).max() ?? 1
            let minWellVisited = max(5, maxV / 4)
            let sign: Double = (resp.rootInfo.currentPlayer.uppercased() == "W") ? -1.0 : 1.0
            let wellVisited = resp.moveInfos.filter { $0.visits >= minWellVisited }.sorted { a, b in
                let utilA = (a.winrate * sign) * 25.0 + (a.scoreLead * sign)
                let utilB = (b.winrate * sign) * 25.0 + (b.scoreLead * sign)
                return utilA > utilB
            }
            let others = resp.moveInfos.filter { $0.visits < minWellVisited }
            resp.moveInfos = wellVisited + others
        }
        if let cont = pendingContinuations.removeValue(forKey: resp.id) {
            cont.resume(returning: resp)
        }
    }

    public func analyze(
        board: BoardState,
        humanSLProfile: String,
        maxVisits: Int = 55,
        includeOwnership: Bool = true
    ) async throws -> KataGoAnalysisResponse {
        try startIfNeeded()
        guard let inHandle = stdinPipe?.fileHandleForWriting else {
            throw NSError(domain: "KataGoService", code: 1, userInfo: [NSLocalizedDescriptionKey: "KataGo stdin unavailable"])
        }

        let reqId = UUID().uuidString
        let initialStonesPayload: [[String]] = board.initialStones.map { (color, pt) in
            [color.rawValue, pt.toGTP(boardSize: board.size)]
        }
        let movesPayload: [[String]] = board.moveHistory.map { rec in
            [rec.color.rawValue, rec.action.toGTP(boardSize: board.size)]
        }

        var query: [String: Any] = [
            "id": reqId,
            "rules": "japanese",
            "komi": board.komi,
            "boardXSize": board.size,
            "boardYSize": board.size,
            "moves": movesPayload,
            "maxVisits": maxVisits,
            "includeOwnership": includeOwnership,
            "includePolicy": true
        ]
        if !initialStonesPayload.isEmpty {
            query["initialStones"] = initialStonesPayload
            query["initialPlayer"] = board.initialPlayer.rawValue
        }
        if hasHumanSLModel {
            query["overrideSettings"] = [
                "humanSLProfile": humanSLProfile,
                "humanSLRootExploreProbWeightless": 0.5
            ]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: query, options: [])
        var lineData = jsonData
        lineData.append(UInt8(ascii: "\n"))

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<KataGoAnalysisResponse, Error>) in
            pendingContinuations[reqId] = continuation
            do {
                try inHandle.write(contentsOf: lineData)
            } catch {
                pendingContinuations.removeValue(forKey: reqId)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Selects a realistic human-like opponent move calibrated to the target rank.
    public nonisolated func selectHumanLikeMove(
        from analysis: KataGoAnalysisResponse,
        board: BoardState,
        temperature: Double = 0.80
    ) -> MoveAction {
        if let topMove = analysis.moveInfos.first, topMove.move.lowercased() == "pass" {
            return .pass
        }
        if board.consecutivePasses >= 1,
           let passInfo = analysis.moveInfos.first(where: { $0.move.lowercased() == "pass" }),
           let bestInfo = analysis.moveInfos.first,
           abs(passInfo.scoreLead - bestInfo.scoreLead) < 1.5 {
            return .pass
        }

        let size = board.size
        if let hp = analysis.humanPolicy, hp.count >= size * size {
            var candidates: [(BoardPoint, Double)] = []
            for r in 0..<size {
                for c in 0..<size {
                    let prob = hp[r * size + c]
                    guard prob >= 0.008 else { continue }
                    let pt = BoardPoint(col: c, row: r)
                    if case .success = board.canPlay(at: pt) {
                        let adjProb = pow(prob, 1.0 / max(temperature, 0.25))
                        candidates.append((pt, adjProb))
                    }
                }
            }

            if !candidates.isEmpty {
                let totalWeight = candidates.reduce(0.0) { $0 + $1.1 }
                if totalWeight > 0 {
                    let roll = Double.random(in: 0..<totalWeight)
                    var accum = 0.0
                    for (pt, w) in candidates {
                        accum += w
                        if roll <= accum {
                            return .place(pt)
                        }
                    }
                    return .place(candidates[0].0)
                }
            }
        }

        for info in analysis.moveInfos {
            if info.move.lowercased() == "pass" { return .pass }
            if let pt = BoardPoint.fromGTP(info.move, boardSize: size),
               case .success = board.canPlay(at: pt) {
                return .place(pt)
            }
        }

        return .pass
    }

    public func stop() {
        readTask?.cancel()
        readTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        isReady = false
    }

    private static func locateBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/katago",
            "/usr/local/bin/katago"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/opt/homebrew/bin/katago"
    }

    private static func locateMainModel() -> String {
        let dirs = [
            "/opt/homebrew/opt/katago/share/katago",
            "/usr/local/opt/katago/share/katago"
        ]
        for dir in dirs {
            let preferred = "\(dir)/kata1-b18c384nbt-s9996604416-d4316597426.bin.gz"
            if FileManager.default.fileExists(atPath: preferred) {
                return preferred
            }
            let secondary = "\(dir)/g170e-b20c256x2-s5303129600-d1228401921.bin.gz"
            if FileManager.default.fileExists(atPath: secondary) {
                return secondary
            }
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir),
               let anyModel = files.sorted().first(where: { $0.hasSuffix(".bin.gz") && !$0.contains("human") }) {
                return "\(dir)/\(anyModel)"
            }
        }
        return "/opt/homebrew/opt/katago/share/katago/kata1-b18c384nbt-s9996604416-d4316597426.bin.gz"
    }

    private static func locateHumanModel() -> String? {
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().path
        let candidates = [
            Bundle.main.resourcePath.map { "\($0)/models/b18c384nbt-humanv0.bin.gz" },
            "\(bundleParent)/Resources/models/b18c384nbt-humanv0.bin.gz",
            "\(FileManager.default.currentDirectoryPath)/Resources/models/b18c384nbt-humanv0.bin.gz"
        ].compactMap { $0 }

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }
}
