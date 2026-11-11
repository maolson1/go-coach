import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct LoadSGFSheet: View {
    public enum LoadMode: String, CaseIterable, Identifiable {
        case playFromMove = "Play from Move"
        case reviewGame = "Review Game"
        public var id: String { rawValue }
    }

    public enum ReviewSide: String, CaseIterable, Identifiable {
        case black = "Black"
        case white = "White"
        case both = "Both"
        public var id: String { rawValue }

        public var stoneColor: StoneColor? {
            switch self {
            case .black: return .black
            case .white: return .white
            case .both: return nil
            }
        }
    }

    @ObservedObject var session: GameSession
    @Environment(\.dismiss) private var dismiss

    @State private var loadMode: LoadMode = .reviewGame
    @State private var sgfText: String = ""
    @State private var sgfInspection: BoardState.SGFInspection? = nil
    @State private var sgfStartMove: Int = 0
    @State private var sgfPreviewBoard: BoardState? = nil
    @State private var sgfFileError: String? = nil

    @State private var selectedColor: StoneColor = .black
    @State private var reviewSide: ReviewSide = .black
    @State private var mistakeThreshold: Double = 3.0

    public init(session: GameSession) {
        self.session = session
    }

    private var canProceed: Bool {
        guard let info = sgfInspection else { return false }
        switch loadMode {
        case .playFromMove:
            return sgfPreviewBoard != nil
        case .reviewGame:
            return info.totalMoves > 0
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Load SGF")
                    .font(.headline)
                Spacer()
                Picker("", selection: $loadMode) {
                    ForEach(LoadMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
            }

            Divider()

            Form {
                Section("SGF Source") {
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
                        .frame(height: 82)
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
                }

                if loadMode == .playFromMove {
                    Section("Play from Position") {
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
                } else {
                    Section("Game Review Settings") {
                        Picker("Review Mistakes For:", selection: $reviewSide) {
                            ForEach(ReviewSide.allCases) { side in
                                Text(side.rawValue).tag(side)
                            }
                        }
                        .pickerStyle(.segmented)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Flag moves that lose ≥")
                                Spacer()
                                Text(String(format: "%.1f pts", mistakeThreshold))
                                    .font(.system(.body, design: .monospaced))
                                    .bold()
                            }
                            Slider(value: $mistakeThreshold, in: 1.5...8.0, step: 0.5)
                        }
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

                Button(loadMode == .reviewGame ? "Start Review" : "Start Game") {
                    session.blunderScoreThreshold = mistakeThreshold
                    if loadMode == .reviewGame {
                        if let fullBoard = BoardState.fromSGF(sgfText, upToMove: nil) {
                            session.startGameReview(fullBoard: fullBoard, reviewColor: reviewSide.stoneColor)
                            dismiss()
                        }
                    } else if let customBoard = sgfPreviewBoard {
                        session.startGameFromBoard(customBoard, humanColor: selectedColor)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceed)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500, height: 470)
        .onAppear {
            selectedColor = session.humanColor
            reviewSide = session.humanColor == .white ? .white : .black
            mistakeThreshold = session.blunderScoreThreshold
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
