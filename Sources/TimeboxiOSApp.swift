import SwiftUI

@main
struct TimeboxiOSApp: App {
    @StateObject private var connection = TimeboxConnection()

    var body: some Scene {
        WindowGroup {
            ModuleHubView()
                .environmentObject(connection)
        }
    }
}
