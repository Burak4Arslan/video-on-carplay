import SwiftUI

// Video on CarPlay: pictures and video on the car's CarPlay screen through the Now Playing artwork.
@main
struct VideoOnCarPlayApp: App {
    @StateObject private var screen = CarScreen()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                CarPlayView(screen: screen)
            }
        }
    }
}
