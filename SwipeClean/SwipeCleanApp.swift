import SwiftUI

@main
struct SwipeCleanApp: App {
    @State private var deck = PhotoDeck()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(deck)
                .preferredColorScheme(.dark)
        }
    }
}
