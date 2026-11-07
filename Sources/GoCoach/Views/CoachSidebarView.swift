import SwiftUI

public struct CoachSidebarView: View {
    @ObservedObject var session: GameSession
    @State private var questionInput: String = ""

    public init(session: GameSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            evaluationHeader
            Divider()

            if let intervention = session.activeIntervention {
                interventionCard(intervention)
                Divider()
            }

            if !session.variationBranches.isEmpty {
                variationsSection
                Divider()
            }

            coachChatList

            Divider()
            askCoachFooter
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 1. Evaluation & Winrate Header
    private var evaluationHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Color.black).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
                    Text("B: \(Int((session.blackWinrate * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text("(\(session.board.capturesByBlack) cap)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                let lead = session.blackScoreLead
                let leadStr = String(format: "%@ +%.1f", lead >= 0 ? "B" : "W", abs(lead))
                Text(leadStr)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())

                Spacer()

                HStack(spacing: 6) {
                    Text("(\(session.board.capturesByWhite) cap)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("W: \(Int(((1.0 - session.blackWinrate) * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Circle().fill(Color.white).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.gray.opacity(0.6), lineWidth: 1))
                }
            }

            // Winrate bar
            GeometryReader { geo in
                let bWidth = max(0, min(geo.size.width, geo.size.width * session.blackWinrate))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.90))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(white: 0.16))
                        .frame(width: bWidth)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                )
            }
            .frame(height: 10)

            // Mini winrate history sparkline if moves exist
            if session.board.moveHistory.count >= 2 {
                winrateSparkline
                    .frame(height: 34)
            }

            if let ratingNote = session.ratingManager.lastRatingChangeNote {
                Text(ratingNote)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var winrateSparkline: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var midLine = Path()
            midLine.move(to: CGPoint(x: 0, y: midY))
            midLine.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(midLine, with: .color(.gray.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            let moves = session.board.moveHistory
            guard moves.count >= 2 else { return }
            let stepX = size.width / CGFloat(max(1, moves.count - 1))

            var line = Path()
            var started = false
            for (idx, m) in moves.enumerated() {
                let wr = m.blackWinrateAfter ?? 0.5
                let x = CGFloat(idx) * stepX
                let y = size.height * CGFloat(1.0 - wr)
                if !started {
                    line.move(to: CGPoint(x: x, y: y))
                    started = true
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }

                if let loss = m.scoreLoss, loss >= session.blunderScoreThreshold {
                    let dot = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dot), with: .color(.orange))
                }
            }
            context.stroke(line, with: .color(.accentColor), lineWidth: 1.6)
        }
    }

    // MARK: - 2. Immediate Pause-on-Blunder Intervention Card
    @ViewBuilder
    private func interventionCard(_ intervention: BlunderIntervention) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Coach Intervention — Move #\(intervention.moveNumber) (\(intervention.playedMoveGTP))")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(String(format: "-%.1f pts (-%.0f%%)", intervention.scoreLoss, intervention.winrateDropPercent))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }

            Text("Game paused before opponent replies. KataGo prefers **\(intervention.bestMoveGTP)** here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    session.takeBackAndRetry()
                } label: {
                    Label("Take Back & Try Again", systemImage: "arrow.uturn.backward.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)

                Button {
                    session.keepPlayingAfterBlunder()
                } label: {
                    Label("Keep Playing", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.09))
    }

    // MARK: - 3. Interactive Variation Branches
    private var variationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Interactive Board Variations (Click to Step Through)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if session.selectedVariationID != nil {
                    Button("Hide") {
                        session.selectedVariationID = nil
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }

            ForEach(session.variationBranches) { branch in
                let isSelected = (session.selectedVariationID == branch.id)
                Button {
                    if isSelected {
                        session.selectedVariationID = nil
                    } else {
                        session.selectedVariationID = branch.id
                        session.variationStepLimit = branch.steps.count
                    }
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(branch.isRecommended ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(branch.title)
                                    .font(.system(size: 12, weight: .bold))
                                Text("• \(branch.subtitle)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(branch.steps.map { "\($0.stepNumber).\($0.gtp)" }.joined(separator: " → "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: isSelected ? "eye.fill" : "eye")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.2)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    // MARK: - 4. Coach Chat History
    private var coachChatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.chatHistory) { item in
                        chatBubble(item)
                            .id(item.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: session.chatHistory.count) { _, _ in
                if let lastID = session.chatHistory.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatBubble(_ entry: ChatEntry) -> some View {
        let isCoach = (entry.role == "coach")
        VStack(alignment: isCoach ? .leading : .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: isCoach ? "graduationcap.fill" : "person.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isCoach ? Color.accentColor : Color.secondary)
                Text(isCoach ? "Go Coach" : "You")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if entry.moveNumber > 0 {
                    Text("• Move #\(entry.moveNumber)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let badge = entry.sourceBadge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
            }

            Text(entry.text.isEmpty ? "Thinking..." : entry.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isCoach ? Color.secondary.opacity(0.10) : Color.accentColor.opacity(0.15))
                )
        }
    }

    // MARK: - 5. Ask Coach Footer & Token Efficiency Meter
    private var askCoachFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Ask about this position (e.g. 'Why not D5?')", text: $questionInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submitQuestion()
                    }

                Button {
                    submitQuestion()
                } label: {
                    if session.isCoachStreaming {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(questionInput.trimmingCharacters(in: .whitespaces).isEmpty ? "Ask Coach" : "Send", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isCoachStreaming)
            }

            HStack {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("Token-Efficient Mode: \(session.ratingManager.localMovesFilteredCount) normal moves filtered locally (0 tokens) • \(session.llmCallsThisGame) coach calls (~\(session.estimatedTokensThisGame) tokens)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
    }

    private func submitQuestion() {
        let q = questionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        questionInput = ""
        Task {
            await session.askCoachOnDemand(question: q.isEmpty ? nil : q)
        }
    }
}
