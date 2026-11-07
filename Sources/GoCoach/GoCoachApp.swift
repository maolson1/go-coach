import AppKit
import SwiftUI

@main
struct GoCoachApp: App {
    @StateObject private var session: GameSession

    init() {
        let rm = PlayerRatingManager()
        let gs = GameSession(ratingManager: rm)
        _session = StateObject(wrappedValue: gs)
    }

    var body: some Scene {
        WindowGroup("GoCoach — KataGo & Antigravity Go Trainer") {
            MainWindowView(session: session)
                .frame(minWidth: 920, minHeight: 640)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
                       let img = NSImage(contentsOfFile: iconPath) {
                        NSApplication.shared.applicationIconImage = img
                    } else if let img = NSImage(contentsOfFile: "/Users/matt/go-coach/Resources/AppIcon.icns") {
                        NSApplication.shared.applicationIconImage = img
                    }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if session.chatHistory.isEmpty {
                        session.startNewGame(size: 19, humanColor: .black, handicap: 0)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New 9×9 Game") {
                    session.startNewGame(size: 9, humanColor: session.humanColor, handicap: 0)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("New 13×13 Game") {
                    session.startNewGame(size: 13, humanColor: session.humanColor, handicap: 0)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("New 19×19 Game") {
                    session.startNewGame(size: 19, humanColor: session.humanColor, handicap: 0)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
