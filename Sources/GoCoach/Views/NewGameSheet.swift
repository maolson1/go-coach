import SwiftUI

public struct NewGameSheet: View {
    @ObservedObject var session: GameSession
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSize: Int = 19
    @State private var selectedColor: StoneColor = .black
    @State private var selectedHandicap: Int = 0
    @State private var selectedRank: GoRank = GoRank(label: "10k")
    @State private var autoCalibrate: Bool = true
    @State private var blunderThreshold: Double = 3.0

    public init(session: GameSession) {
        self.session = session
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "circle.grid.cross.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("New Game")
                    .font(.headline)
            }

            Divider()

            Form {
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
                    session.startNewGame(
                        size: selectedSize,
                        humanColor: selectedColor,
                        handicap: selectedHandicap
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 470)
        .onAppear {
            selectedSize = session.board.size
            selectedColor = session.humanColor
            selectedHandicap = session.board.handicap
            selectedRank = session.ratingManager.currentRank
            autoCalibrate = session.ratingManager.autoCalibrateStrength
            blunderThreshold = session.blunderScoreThreshold
        }
    }
}
