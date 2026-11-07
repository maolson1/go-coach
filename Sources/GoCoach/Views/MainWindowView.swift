import SwiftUI

public struct MainWindowView: View {
    @ObservedObject var session: GameSession
    @State private var showingNewGameSheet: Bool = false

    public init(session: GameSession) {
        self.session = session
    }

    public var body: some View {
        HSplitView {
            // Left: Goban Board + Top/Bottom Status Bars
            VStack(spacing: 0) {
                boardHeaderBar
                Divider()

                ZStack {
                    Color(NSColor.underPageBackgroundColor)
                    GobanView(session: session)
                }

                if let err = session.errorBanner {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Dismiss") {
                            session.errorBanner = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.12))
                }

                Divider()
                boardBottomControls
            }
            .frame(minWidth: 520, idealWidth: 680, maxWidth: .infinity, maxHeight: .infinity)

            // Right: Coach & Variations Sidebar
            CoachSidebarView(session: session)
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 480, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingNewGameSheet) {
            NewGameSheet(session: session)
        }
    }

    private var boardHeaderBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.board.nextToPlay == .black ? Color.black : Color.white)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.gray, lineWidth: 1))
                Text(session.statusText)
                    .font(.system(size: 13, weight: .semibold))
            }

            if session.isEngineThinking {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            // Quick board size switcher
            Menu {
                Button("New 9×9 Game") {
                    session.startNewGame(size: 9, humanColor: session.humanColor, handicap: 0)
                }
                Button("New 13×13 Game") {
                    session.startNewGame(size: 13, humanColor: session.humanColor, handicap: 0)
                }
                Button("New 19×19 Game") {
                    session.startNewGame(size: 19, humanColor: session.humanColor, handicap: 0)
                }
                Divider()
                Button("Custom Game Setup...") {
                    showingNewGameSheet = true
                }
            } label: {
                Label("\(session.board.size)×\(session.board.size)", systemImage: "square.grid.3x3")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Rank & dynamic calibration menu
            Menu {
                Toggle("Dynamic Auto-Calibration", isOn: Binding(
                    get: { session.ratingManager.autoCalibrateStrength },
                    set: { session.ratingManager.autoCalibrateStrength = $0 }
                ))
                Divider()
                ForEach([20, 15, 12, 10, 8, 6, 4, 2, 1], id: \.self) { k in
                    let r = GoRank(label: "\(k)k")
                    Button("Set Rank: \(r.label)") {
                        session.ratingManager.setManualRank(r)
                    }
                }
                Divider()
                ForEach(1...5, id: \.self) { d in
                    let r = GoRank(label: "\(d)d")
                    Button("Set Rank: \(r.label)") {
                        session.ratingManager.setManualRank(r)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.badge.shield.checkmark.fill")
                    Text("Rank: \(session.ratingManager.currentRank.label)")
                    if session.ratingManager.autoCalibrateStrength {
                        Text("(Auto)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var boardBottomControls: some View {
        HStack(spacing: 10) {
            Button {
                showingNewGameSheet = true
            } label: {
                Label("New Game", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)

            Button {
                session.passHumanTurn()
            } label: {
                Label("Pass", systemImage: "forward.frame")
            }
            .buttonStyle(.bordered)
            .disabled(session.isEngineThinking || session.activeIntervention != nil || session.gameResultSummary != nil)

            Button {
                session.undoLastExchange()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .disabled(session.board.moveHistory.isEmpty || session.isEngineThinking)

            Button {
                session.resignGame()
            } label: {
                Label("Resign", systemImage: "flag")
            }
            .buttonStyle(.bordered)
            .disabled(session.board.moveHistory.isEmpty || session.gameResultSummary != nil)

            Spacer()

            Toggle(isOn: $session.showCandidateHints) {
                Label("Hints", systemImage: "lightbulb")
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Toggle(isOn: $session.showOwnershipMap) {
                Label("Territory", systemImage: "square.grid.2x2")
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Button {
                session.copySGFToClipboard()
            } label: {
                Label("Copy SGF", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
