import Foundation

public struct CoachingMeta: Codable, Sendable {
    public let playedMove: String
    public let bestMove: String
    public let secondMove: String?
    public let scoreLoss: Double
    public let winrateDropPercent: Double
    public let scoreLeadAfter: Double
    public let phase: String
    public let tacticalTags: [String]
    public let ownershipShifts: [String]
    public let pvOutcomes: [String]
    public let counterfactualNotes: [String]
    public let bestPV: [String]
    public let punishPV: [String]
    public let playedHumanProb: Double?
    public let bestHumanProb: Double?
    public let playerRank: String
    public let severity: String

    public init(
        playedMove: String,
        bestMove: String,
        secondMove: String?,
        scoreLoss: Double,
        winrateDropPercent: Double,
        scoreLeadAfter: Double,
        phase: String,
        tacticalTags: [String],
        ownershipShifts: [String] = [],
        pvOutcomes: [String] = [],
        counterfactualNotes: [String] = [],
        bestPV: [String],
        punishPV: [String],
        playedHumanProb: Double?,
        bestHumanProb: Double?,
        playerRank: String,
        severity: String
    ) {
        self.playedMove = playedMove
        self.bestMove = bestMove
        self.secondMove = secondMove
        self.scoreLoss = scoreLoss
        self.winrateDropPercent = winrateDropPercent
        self.scoreLeadAfter = scoreLeadAfter
        self.phase = phase
        self.tacticalTags = tacticalTags
        self.ownershipShifts = ownershipShifts
        self.pvOutcomes = pvOutcomes
        self.counterfactualNotes = counterfactualNotes
        self.bestPV = bestPV
        self.punishPV = punishPV
        self.playedHumanProb = playedHumanProb
        self.bestHumanProb = bestHumanProb
        self.playerRank = playerRank
        self.severity = severity
    }
}

public actor CoachBridgeService {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var chunkHandlers: [String: @Sendable (String) -> Void] = [:]
    private var doneContinuations: [String: CheckedContinuation<(text: String, source: String), Error>] = [:]

    public init() {}

    public func startIfNeeded() throws {
        if let proc = process, proc.isRunning {
            return
        }

        let workspaceRoot = Self.locateWorkspaceRoot()
        let pythonPath = Self.locatePython(workspaceRoot: workspaceRoot)
        let scriptPath = Self.locateBridgeScript(workspaceRoot: workspaceRoot)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        var env = ProcessInfo.processInfo.environment
        env["GOCOACH_WORKSPACE"] = workspaceRoot
        proc.environment = env
        proc.arguments = [scriptPath]

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

        let handle = outPipe.fileHandleForReading
        self.readTask = Task.detached { [weak self] in
            var buffer = Data()
            let newline = UInt8(ascii: "\n")
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    await self?.handleProcessEOF()
                    break
                }
                buffer.append(chunk)
                while let idx = buffer.firstIndex(of: newline) {
                    let line = buffer.subdata(in: 0..<idx)
                    buffer.removeSubrange(0...idx)
                    if !line.isEmpty {
                        await self?.handleLine(line)
                    }
                }
            }
        }
    }

    private func handleProcessEOF() {
        process = nil
        chunkHandlers.removeAll()
        let err = NSError(domain: "CoachBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Coach bridge process exited"])
        let all = doneContinuations
        doneContinuations.removeAll()
        for (_, cont) in all {
            cont.resume(throwing: err)
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let event = obj["event"] as? String else {
            return
        }

        switch event {
        case "chunk":
            if let text = obj["text"] as? String, let handler = chunkHandlers[id] {
                handler(text)
            }
        case "done":
            let fullText = (obj["full_text"] as? String) ?? ""
            let source = (obj["source"] as? String) ?? "antigravity"
            chunkHandlers.removeValue(forKey: id)
            if let cont = doneContinuations.removeValue(forKey: id) {
                cont.resume(returning: (fullText, source))
            }
        case "error":
            let errMsg = (obj["error"] as? String) ?? "Unknown coach bridge error"
            chunkHandlers.removeValue(forKey: id)
            if let cont = doneContinuations.removeValue(forKey: id) {
                cont.resume(throwing: NSError(domain: "CoachBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: errMsg]))
            }
        default:
            break
        }
    }

    public func requestCoaching(
        type: String = "advice",
        digest: String,
        question: String? = nil,
        meta: CoachingMeta,
        resetSession: Bool = true,
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> (text: String, source: String) {
        try startIfNeeded()
        guard let inHandle = stdinPipe?.fileHandleForWriting else {
            throw NSError(domain: "CoachBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Coach bridge stdin closed"])
        }

        let reqId = UUID().uuidString
        let metaData = try JSONEncoder().encode(meta)
        let metaDict = (try JSONSerialization.jsonObject(with: metaData) as? [String: Any]) ?? [:]

        var payload: [String: Any] = [
            "id": reqId,
            "type": type,
            "digest": digest,
            "meta": metaDict,
            "reset_session": resetSession
        ]
        if let q = question {
            payload["question"] = q
        }

        var lineData = try JSONSerialization.data(withJSONObject: payload)
        lineData.append(UInt8(ascii: "\n"))

        return try await withCheckedThrowingContinuation { continuation in
            chunkHandlers[reqId] = onChunk
            doneContinuations[reqId] = continuation
            do {
                try inHandle.write(contentsOf: lineData)
            } catch {
                chunkHandlers.removeValue(forKey: reqId)
                doneContinuations.removeValue(forKey: reqId)
                continuation.resume(throwing: error)
            }
        }
    }

    public func stop() {
        readTask?.cancel()
        readTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }

    private static func locateWorkspaceRoot() -> String {
        if let envRoot = ProcessInfo.processInfo.environment["GOCOACH_WORKSPACE"],
           FileManager.default.fileExists(atPath: envRoot) {
            return envRoot
        }
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().path
        if FileManager.default.fileExists(atPath: "\(bundleParent)/scripts/coach_bridge.py") ||
           FileManager.default.fileExists(atPath: "\(bundleParent)/Package.swift") {
            return bundleParent
        }
        return FileManager.default.currentDirectoryPath
    }

    private static func locatePython(workspaceRoot: String) -> String {
        let candidates = [
            "\(workspaceRoot)/.venv/bin/python",
            "\(FileManager.default.currentDirectoryPath)/.venv/bin/python",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/python3"
    }

    private static func locateBridgeScript(workspaceRoot: String) -> String {
        let candidates = [
            "\(workspaceRoot)/scripts/coach_bridge.py",
            Bundle.main.resourcePath.map { "\($0)/scripts/coach_bridge.py" },
            "\(FileManager.default.currentDirectoryPath)/scripts/coach_bridge.py"
        ].compactMap { $0 }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return "\(workspaceRoot)/scripts/coach_bridge.py"
    }
}
