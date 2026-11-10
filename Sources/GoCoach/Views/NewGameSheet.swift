import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct NewGameSheet: View {
    private enum SetupMode: String, CaseIterable, Identifiable {
        case standard = "Standard Game"
        case sgf = "Load SGF Position"
        var id: String { rawValue }
    }

    @ObservedObject var session: GameSession
    @Environment(\.dismiss) private var dismiss

    @State private var setupMode: SetupMode = .standard
    @State private var selectedSize: Int = 19
    @State private var selectedColor: StoneColor = .black
    @State private var selectedHandicap: Int = 0
    @State private var selectedRank: GoRank = GoRank(label: "10k")
    @State private var autoCalibrate: Bool = true
    @State private var blunderThreshold: Double = 3.0

    // SGF setup state
    @State private var sgfText: String = ""
    @State private var sgfInspection: BoardState.SGFInspection? = nil
    @State private var sgfStartMove: Int = 0
    @State private var sgfPreviewBoard: BoardState? = nil
    @State private var sgfFileError: String? = nil

    public init(session: GameSession) {
        self.session = session
    }

    private var canStartGame: Bool {
        switch setupMode {
        case .standard:
            return true
        case .sgf:
            return sgfPreviewBoard != nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "circle.grid.cross.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("New Game")
                    .font(.headline)
                Spacer()
                Picker("", selection: $setupMode) {
                    ForEach(SetupMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            Divider()

            Form {
                if setupMode == .standard {
                    Picker("Board Size:", selection: $selectedSize) {
                        Text("9×9").tag(9)
                        Text("13×13").tag(13)
                        Text("19×19").tag(19)
                    }
                    .pickerStyle(.segmented)

                    Picker("Your Color:", selection: $selectedColor) {
                        Text("Black").tag(StoneColor.black)
                        Text("White").tag(StoneColor.white)
                    }
                    .pickerStyle(.segmented)

                    Picker("Handicap Stones:", selection: $selectedHandicap) {
                        Text("None").tag(0)
                        ForEach(2...9, id: \.self) { h in
                            Text("\(h) Stones").tag(h)
                        }
                    }
                } else {
                    Section("SGF Game or Position") {
                        HStack(spacing: 8) {
                            Button {
                                if let pasted = NSPasteboard.general.string(forType: .string) {
                                    loadSGFString(pasted)
                                }
                            } label: {
                                Label("Paste SGF", systemImage: "doc.on.clipboard")
                            }
                            .controlSize(.small)

                            Button {
                                openSGFFilePanel()
                            } label: {
                                Label("Open .sgf File...", systemImage: "folder")
                            }
                            .controlSize(.small)

                            if !sgfText.isEmpty {
                                Button("Clear") {
                                    sgfText = ""
                                    sgfInspection = nil
                                    sgfPreviewBoard = nil
                                    sgfFileError = nil
                                }
                                .controlSize(.small)
                            }

                            Spacer()

                            if let info = sgfInspection {
                                let detail = info.totalMoves > 0
                                    ? "\(info.totalMoves) moves"
                                    : "\(info.setupStoneCount) setup stones"
                                Text("✓ \(info.boardSize)×\(info.boardSize) • \(detail)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.green)
                            } else if !sgfText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Invalid SGF")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.red)
                            }
                        }

                        TextEditor(text: $sgfText)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 68)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .onChange(of: sgfText) { _, newValue in
                                handleSGFTextEdited(newValue)
                            }

                        if let err = sgfFileError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }

                        if let info = sgfInspection, info.totalMoves > 0 {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Start at Move #:")
                                        .font(.system(size: 12, weight: .medium))
                                    TextField(
                                        "",
                                        value: $sgfStartMove,
                                        formatter: NumberFormatter()
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 58)
                                    .font(.system(size: 12, design: .monospaced))

                                    Stepper("", value: $sgfStartMove, in: 0...info.totalMoves)
                                        .labelsHidden()

                                    Text("of \(info.totalMoves)")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    if let preview = sgfPreviewBoard {
                                        Text("Next: Move #\(preview.currentMoveNumber + 1) (\(preview.nextToPlay.displayName))")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }

                                Slider(
                                    value: Binding(
                                        get: { Double(sgfStartMove) },
                                        set: { sgfStartMove = Int($0.rounded()) }
                                    ),
                                    in: 0...Double(max(1, info.totalMoves)),
                                    step: 1
                                )
                            }
                            .onChange(of: sgfStartMove) { _, newMove in
                                let clamped = max(0, min(info.totalMoves, newMove))
                                if clamped != newMove {
                                    sgfStartMove = clamped
                                }
                                rebuildSGFPreview(upToMove: clamped, syncPlayerColor: true)
                            }
                        }

                        Picker("Your Color:", selection: $selectedColor) {
                            Text("Black").tag(StoneColor.black)
                            Text("White").tag(StoneColor.white)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section("Human-Like Opponent & Dynamic Rating") {
                    Toggle("Dynamically adjust opponent strength from my games", isOn: $autoCalibrate)

                    Picker("Current Calibrated Rank:", selection: $selectedRank) {
                        ForEach(GoRank.allRanks) { r in
                            Text("\(r.label) (\(r.displayName))").tag(r)
                        }
                    }
                }

                Section("Coach Intervention Threshold") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pause before opponent replies when move loses ≥")
                            Spacer()
                            Text(String(format: "%.1f pts", blunderThreshold))
                                .font(.system(.body, design: .monospaced))
                                .bold()
                        }
                        Slider(value: $blunderThreshold, in: 1.5...8.0, step: 0.5)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start Game") {
                    session.ratingManager.autoCalibrateStrength = autoCalibrate
                    if selectedRank != session.ratingManager.currentRank {
                        session.ratingManager.setManualRank(selectedRank)
                    }
                    session.blunderScoreThreshold = blunderThreshold

                    if setupMode == .sgf, let customBoard = sgfPreviewBoard {
                        session.startGameFromBoard(customBoard, humanColor: selectedColor)
                    } else {
                        session.startNewGame(
                            size: selectedSize,
                            humanColor: selectedColor,
                            handicap: selectedHandicap
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartGame)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: setupMode == .sgf ? 560 : 450)
        .onAppear {
            selectedSize = session.board.size
            selectedColor = session.humanColor
            selectedHandicap = session.board.handicap
            selectedRank = session.ratingManager.currentRank
            autoCalibrate = session.ratingManager.autoCalibrateStrength
            blunderThreshold = session.blunderScoreThreshold
        }
    }

    private func loadSGFString(_ raw: String) {
        sgfFileError = nil
        sgfText = raw
        if let info = BoardState.inspectSGF(raw) {
            sgfInspection = info
            sgfStartMove = info.totalMoves
            rebuildSGFPreview(upToMove: info.totalMoves, syncPlayerColor: true)
        } else {
            sgfInspection = nil
            sgfPreviewBoard = nil
        }
    }

    private func handleSGFTextEdited(_ raw: String) {
        sgfFileError = nil
        if let info = BoardState.inspectSGF(raw) {
            let previousTotal = sgfInspection?.totalMoves
            sgfInspection = info
            if previousTotal != info.totalMoves {
                sgfStartMove = info.totalMoves
            }
            rebuildSGFPreview(upToMove: sgfStartMove, syncPlayerColor: true)
        } else {
            sgfInspection = nil
            sgfPreviewBoard = nil
        }
    }

    private func rebuildSGFPreview(upToMove moveLimit: Int, syncPlayerColor: Bool) {
        guard let board = BoardState.fromSGF(sgfText, upToMove: moveLimit) else {
            sgfPreviewBoard = nil
            return
        }
        sgfPreviewBoard = board
        if syncPlayerColor {
            selectedColor = board.nextToPlay
        }
    }

    private func openSGFFilePanel() {
        let panel = NSOpenPanel()
        panel.title = "Open SGF Game or Position"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let sgfType = UTType(filenameExtension: "sgf") {
            panel.allowedContentTypes = [sgfType, .plainText]
        }
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let contents: String
                if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                    contents = utf8
                } else {
                    contents = try String(contentsOf: url, encoding: .isoLatin1)
                }
                loadSGFString(contents)
            } catch {
                sgfFileError = "Could not read file: \(error.localizedDescription)"
            }
        }
    }
}
