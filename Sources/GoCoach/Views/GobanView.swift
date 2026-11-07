import SwiftUI

public struct GobanView: View {
    @ObservedObject var session: GameSession
    @State private var hoverPoint: BoardPoint? = nil

    public init(session: GameSession) {
        self.session = session
    }

    private var displayedBoard: BoardState {
        if let branch = session.selectedVariation {
            return branch.baseBoard
        }
        return session.board
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let minDim = min(geo.size.width, geo.size.height)
                let boardSide = max(260.0, minDim - 24.0)

                ZStack {
                    // Kaya wood board background with bevel & shadow
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.87, green: 0.70, blue: 0.42),
                                    Color(red: 0.81, green: 0.63, blue: 0.35),
                                    Color(red: 0.85, green: 0.67, blue: 0.39)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(red: 0.55, green: 0.39, blue: 0.18), lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.38), radius: 14, x: 0, y: 6)

                    boardCanvas(boardSide: boardSide)
                }
                .frame(width: boardSide, height: boardSide)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            // Dedicated bar below the board so it never covers the board or coordinate labels
            if let variation = session.selectedVariation {
                Divider()
                variationOverlayBar(variation: variation)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func boardCanvas(boardSide: CGFloat) -> some View {
        let bState = displayedBoard
        let size = bState.size
        let margin = max(28.0, boardSide * 0.068)
        let gridSpan = boardSide - margin * 2.0
        let cell = size > 1 ? gridSpan / CGFloat(size - 1) : gridSpan
        let stoneRadius = cell * 0.465

        Canvas { context, _ in
            // 1. Subtle wood grain lines
            for i in stride(from: 8.0, to: boardSide, by: 14.0) {
                var grain = Path()
                grain.move(to: CGPoint(x: i, y: 4))
                grain.addLine(to: CGPoint(x: i + 3, y: boardSide - 4))
                context.stroke(grain, with: .color(Color.brown.opacity(0.055)), lineWidth: 1)
            }

            // 2. Grid lines
            let gridColor = Color(red: 0.18, green: 0.13, blue: 0.07)
            for idx in 0..<size {
                let offset = margin + CGFloat(idx) * cell
                let isBorder = (idx == 0 || idx == size - 1)
                let lw: CGFloat = isBorder ? 1.6 : 1.0

                var hPath = Path()
                hPath.move(to: CGPoint(x: margin, y: offset))
                hPath.addLine(to: CGPoint(x: margin + gridSpan, y: offset))
                context.stroke(hPath, with: .color(gridColor), lineWidth: lw)

                var vPath = Path()
                vPath.move(to: CGPoint(x: offset, y: margin))
                vPath.addLine(to: CGPoint(x: offset, y: margin + gridSpan))
                context.stroke(vPath, with: .color(gridColor), lineWidth: lw)
            }

            // 3. Coordinate labels (A-T, 1-19)
            let letters = Array("ABCDEFGHJKLMNOPQRST")
            let fontSize = max(9.0, min(12.0, cell * 0.34))
            for idx in 0..<size {
                let x = margin + CGFloat(idx) * cell
                let y = margin + CGFloat(idx) * cell
                let colLabel = String(letters[idx])
                let rowLabel = "\(size - idx)"

                let colText = Text(colLabel)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(red: 0.25, green: 0.18, blue: 0.08))
                context.draw(colText, at: CGPoint(x: x, y: margin * 0.42))
                context.draw(colText, at: CGPoint(x: x, y: boardSide - margin * 0.42))

                let rowText = Text(rowLabel)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(red: 0.25, green: 0.18, blue: 0.08))
                context.draw(rowText, at: CGPoint(x: margin * 0.42, y: y))
                context.draw(rowText, at: CGPoint(x: boardSide - margin * 0.42, y: y))
            }

            // 4. Star points (Hoshi)
            let stars = BoardState.starPoints(for: size)
            for st in stars {
                let cx = margin + CGFloat(st.col) * cell
                let cy = margin + CGFloat(st.row) * cell
                let r: CGFloat = max(3.0, cell * 0.11)
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(gridColor))
            }

            // 5. Optional Ownership / Territory Heatmap
            if session.showOwnershipMap,
               let ownership = session.latestAnalysis?.ownership,
               ownership.count >= size * size {
                for r in 0..<size {
                    for c in 0..<size {
                        let val = ownership[r * size + c]
                        guard abs(val) > 0.22 else { continue }
                        let cx = margin + CGFloat(c) * cell
                        let cy = margin + CGFloat(r) * cell
                        let sqSide = cell * CGFloat(min(0.56, abs(val) * 0.58))
                        let rect = CGRect(x: cx - sqSide / 2, y: cy - sqSide / 2, width: sqSide, height: sqSide)
                        let color = val > 0 ? Color.black.opacity(0.65) : Color.white.opacity(0.80)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                    }
                }
            }

            // 6. Placed stones on the board
            for r in 0..<size {
                for c in 0..<size {
                    let pt = BoardPoint(col: c, row: r)
                    guard let stoneColor = bState.stone(at: pt) else { continue }
                    let center = CGPoint(x: margin + CGFloat(c) * cell, y: margin + CGFloat(r) * cell)
                    drawStone(context: &context, center: center, radius: stoneRadius, color: stoneColor, opacity: 1.0)
                }
            }

            // 7. Last move marker (when not previewing a variation)
            if session.selectedVariation == nil, let lastPt = bState.lastPlacedPoint {
                let cx = margin + CGFloat(lastPt.col) * cell
                let cy = margin + CGFloat(lastPt.row) * cell
                let markerRadius = stoneRadius * 0.34
                let rect = CGRect(x: cx - markerRadius, y: cy - markerRadius, width: markerRadius * 2, height: markerRadius * 2)
                let isBlack = bState.stone(at: lastPt) == .black
                let ringColor = isBlack ? Color.white.opacity(0.9) : Color.black.opacity(0.85)
                context.stroke(Path(ellipseIn: rect), with: .color(ringColor), lineWidth: 2.2)
            }

            // 8. Candidate hints overlay (when Hint button is active)
            if session.showCandidateHints,
               session.selectedVariation == nil,
               let moves = session.latestAnalysis?.moveInfos.prefix(3) {
                for (i, m) in moves.enumerated() {
                    guard let pt = BoardPoint.fromGTP(m.move, boardSize: size) else { continue }
                    let cx = margin + CGFloat(pt.col) * cell
                    let cy = margin + CGFloat(pt.row) * cell
                    let r = stoneRadius * 0.72
                    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                    let badgeColor = i == 0 ? Color.green : Color.blue
                    context.fill(Path(ellipseIn: rect), with: .color(badgeColor.opacity(0.35)))
                    context.stroke(Path(ellipseIn: rect), with: .color(badgeColor), lineWidth: 2.2)

                    let label = Text(m.move)
                        .font(.system(size: max(9, stoneRadius * 0.55), weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    context.draw(label, at: CGPoint(x: cx, y: cy))
                }
            }

            // 9. Interactive Variation Branch Overlay (numbered stones + trajectory arrows)
            if let variation = session.selectedVariation {
                let activeSteps = Array(variation.steps.prefix(session.variationStepLimit))
                if activeSteps.count >= 2 {
                    var linePath = Path()
                    for (idx, step) in activeSteps.enumerated() {
                        let p = CGPoint(x: margin + CGFloat(step.point.col) * cell, y: margin + CGFloat(step.point.row) * cell)
                        if idx == 0 {
                            linePath.move(to: p)
                        } else {
                            linePath.addLine(to: p)
                        }
                    }
                    let lineColor = variation.isRecommended ? Color.green.opacity(0.75) : Color.orange.opacity(0.75)
                    context.stroke(linePath, with: .color(lineColor), style: StrokeStyle(lineWidth: 2.5, dash: [5, 3]))
                }

                for (idx, step) in activeSteps.enumerated() {
                    let center = CGPoint(x: margin + CGFloat(step.point.col) * cell, y: margin + CGFloat(step.point.row) * cell)
                    drawStone(context: &context, center: center, radius: stoneRadius, color: step.color, opacity: 0.96)

                    // Highlight ring around step 1 and latest step
                    let isLatest = (idx == activeSteps.count - 1)
                    let ringColor = variation.isRecommended ? Color.green : Color.orange
                    let ringRect = CGRect(
                        x: center.x - stoneRadius,
                        y: center.y - stoneRadius,
                        width: stoneRadius * 2,
                        height: stoneRadius * 2
                    )
                    context.stroke(
                        Path(ellipseIn: ringRect),
                        with: .color(ringColor.opacity(isLatest ? 1.0 : 0.65)),
                        lineWidth: isLatest ? 3.0 : 1.8
                    )

                    let numText = Text("\(step.stepNumber)")
                        .font(.system(size: max(10, stoneRadius * 0.85), weight: .heavy, design: .rounded))
                        .foregroundColor(step.color == .black ? .white : .black)
                    context.draw(numText, at: center)
                }
            }

            // 10. Hover ghost stone when it is the human's turn
            if session.selectedVariation == nil,
               session.activeIntervention == nil,
               !session.isEngineThinking,
               session.board.nextToPlay == session.humanColor,
               let hp = hoverPoint,
               case .success = bState.canPlay(at: hp, color: session.humanColor) {
                let center = CGPoint(x: margin + CGFloat(hp.col) * cell, y: margin + CGFloat(hp.row) * cell)
                drawStone(context: &context, center: center, radius: stoneRadius, color: session.humanColor, opacity: 0.42)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                hoverPoint = nearestIntersection(at: loc, margin: margin, cell: cell, size: size)
            case .ended:
                hoverPoint = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    if let pt = nearestIntersection(at: value.location, margin: margin, cell: cell, size: size) {
                        session.handleBoardIntersectionClick(pt)
                    }
                }
        )
    }

    private func nearestIntersection(at location: CGPoint, margin: CGFloat, cell: CGFloat, size: Int) -> BoardPoint? {
        guard cell > 0 else { return nil }
        let colFloat = (location.x - margin) / cell
        let rowFloat = (location.y - margin) / cell
        let col = Int(colFloat.rounded())
        let row = Int(rowFloat.rounded())
        guard col >= 0, col < size, row >= 0, row < size else { return nil }
        let snapDist = hypot(colFloat - CGFloat(col), rowFloat - CGFloat(row))
        guard snapDist <= 0.48 else { return nil }
        return BoardPoint(col: col, row: row)
    }

    private func drawStone(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        color: StoneColor,
        opacity: Double
    ) {
        let shadowRect = CGRect(
            x: center.x - radius + 1.5,
            y: center.y - radius + 2.2,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(Path(ellipseIn: shadowRect), with: .color(Color.black.opacity(0.32 * opacity)))

        let stoneRect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let highlightCenter = CGPoint(x: center.x - radius * 0.30, y: center.y - radius * 0.30)

        if color == .black {
            let grad = Gradient(colors: [
                Color(white: 0.34).opacity(opacity),
                Color(white: 0.12).opacity(opacity),
                Color(white: 0.04).opacity(opacity)
            ])
            context.fill(
                Path(ellipseIn: stoneRect),
                with: .radialGradient(grad, center: highlightCenter, startRadius: 1, endRadius: radius * 1.35)
            )
        } else {
            let grad = Gradient(colors: [
                Color(white: 0.99).opacity(opacity),
                Color(white: 0.93).opacity(opacity),
                Color(white: 0.80).opacity(opacity)
            ])
            context.fill(
                Path(ellipseIn: stoneRect),
                with: .radialGradient(grad, center: highlightCenter, startRadius: 1, endRadius: radius * 1.4)
            )
            context.stroke(Path(ellipseIn: stoneRect), with: .color(Color.black.opacity(0.22 * opacity)), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private func variationOverlayBar(variation: VariationBranch) -> some View {
        let total = max(1, variation.steps.count)
        let current = min(session.variationStepLimit, total)

        HStack(spacing: 12) {
            Circle()
                .fill(variation.isRecommended ? Color.green : Color.orange)
                .frame(width: 9, height: 9)

            Text(variation.title)
                .font(.system(size: 13, weight: .bold))

            Divider().frame(height: 16)

            Button {
                session.variationStepLimit = 1
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .disabled(current <= 1)

            Button {
                session.variationStepLimit = max(1, current - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(current <= 1)

            Text("Move \(current) / \(total)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 74)

            Button {
                session.variationStepLimit = min(total, current + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(current >= total)

            Button {
                session.variationStepLimit = total
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.borderless)
            .disabled(current >= total)

            Divider().frame(height: 16)

            Button("Back to Board") {
                session.selectedVariationID = nil
            }
            .buttonStyle(.borderedProminent)
            .tint(.secondary)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}
