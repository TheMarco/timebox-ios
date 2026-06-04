import SwiftUI

/// Home screen: shared Timebox connection + a list of modules. New modules slot in
/// as more `NavigationLink`s here.
struct ModuleHubView: View {
    @EnvironmentObject private var connection: TimeboxConnection

    var body: some View {
        NavigationStack {
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
                    NavigationLink {
                        NowPlayingView(connection: connection)
                    } label: {
                        Label("Now Playing", systemImage: "music.note")
                    }
                    .disabled(!connection.isConnected)

                    NavigationLink {
                        ManualView()
                    } label: {
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
        }
    }
}
