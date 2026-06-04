import SwiftUI

/// A module the hub can navigate to (and remember across launches).
enum HubModule: String, Hashable {
    case nowPlaying, manual
}

/// Home screen: shared Timebox connection + a list of modules. On launch it auto-reconnects
/// (if it was connected last time) and reopens whichever module was last in use, so the app
/// resumes right where it left off. New modules slot in as more `NavigationLink`s here.
struct ModuleHubView: View {
    @EnvironmentObject private var connection: TimeboxConnection
    @AppStorage("lastModule") private var lastModule: String = ""
    @State private var path: [HubModule] = []
    @State private var didResume = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Timebox") {
                    Text(connection.status).font(.callout)
                    HStack {
                        Button(connection.isConnected ? "Reconnect" : "Scan & Connect") { connection.connect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(connection.busy)
                        Spacer()
                        if connection.isConnected {
                            Button("Disconnect") { connection.disconnect() }
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("Modules") {
                    NavigationLink(value: HubModule.nowPlaying) {
                        Label("Now Playing", systemImage: "music.note")
                    }
                    .disabled(!connection.isConnected)

                    NavigationLink(value: HubModule.manual) {
                        Label("Manual test", systemImage: "slider.horizontal.3")
                    }
                    .disabled(!connection.isConnected)
                }

                if !connection.isConnected {
                    Section {
                        Text("Connect to your Divoom Timebox Evo to open a module.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Unofficial app — not affiliated with, authorized, or endorsed by Divoom. \u{201C}Divoom\u{201D} and \u{201C}Timebox\u{201D} are trademarks of their respective owners.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pixel Labs")
            .navigationDestination(for: HubModule.self) { module in
                switch module {
                case .nowPlaying: NowPlayingView(connection: connection)
                case .manual: ManualView()
                }
            }
        }
        .task { connection.autoConnect() }
        .onChange(of: connection.isConnected) { _, connected in
            // Once the (auto-)connection comes up on launch, reopen the last-used module.
            if connected, !didResume, let module = HubModule(rawValue: lastModule) {
                didResume = true
                path = [module]
            }
        }
        .onChange(of: path) { _, newPath in
            lastModule = newPath.last?.rawValue ?? ""   // remember where we are for next launch
        }
    }
}
