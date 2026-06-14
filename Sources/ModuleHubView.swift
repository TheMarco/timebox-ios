import SwiftUI

/// A module the hub can navigate to (and remember across launches).
enum HubModule: String, Hashable {
    case nowPlaying, clock, weather
}

/// Which Divoom display the user is targeting. Drives the connect buttons and which modules
/// are offered — the 16×16 Timebox Evo only fits Now Playing.
enum DeviceKind: String, CaseIterable {
    case pixoo, timebox
}

/// Home screen: shared display connection + a list of modules. On launch it auto-reconnects
/// (if it was connected last time) and reopens whichever module was last in use, so the app
/// resumes right where it left off. New modules slot in as more `NavigationLink`s here.
struct ModuleHubView: View {
    @EnvironmentObject private var connection: TimeboxConnection
    @AppStorage("lastModule") private var lastModule: String = ""
    @State private var path: [HubModule] = []
    @State private var didResume = false
    @State private var showPixooIPPrompt = false
    @State private var pixooIP = ""
    @AppStorage("deviceKind") private var deviceKindRaw = DeviceKind.pixoo.rawValue
    private var deviceKind: DeviceKind { DeviceKind(rawValue: deviceKindRaw) ?? .pixoo }
    /// Clock + Weather are 64×64-only (Pixoo). A connected Timebox Evo (16×16) gets just Now Playing;
    /// before connecting, the device dropdown decides.
    private var showsRichModules: Bool {
        connection.isConnected ? connection.profile.width >= 64 : deviceKind == .pixoo
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Display") {
                    Text(connection.status).font(.callout)
                    if connection.isConnected {
                        Button("Disconnect") { connection.disconnect() }
                            .foregroundStyle(.red)
                    } else {
                        // Timebox Evo is disabled for now — Pixoo 64 only. (The device picker and
                        // Bluetooth connect path are intentionally left in the codebase, just unused.)
                        Button("Find Pixoo 64 on Wi-Fi") { connection.connectPixooAuto() }
                            .buttonStyle(.borderedProminent)
                            .disabled(connection.busy)
                        Button("Enter Pixoo 64 IP…") {
                            pixooIP = connection.lastPixooHost
                            showPixooIPPrompt = true
                        }
                        .disabled(connection.busy)
                    }
                }

                // Every module renders a live on-screen preview, so they all work without a
                // device connected — connecting just mirrors the same render onto the Pixoo.
                Section("Modules") {
                    NavigationLink(value: HubModule.nowPlaying) {
                        Label("Now Playing", systemImage: "music.note")
                    }

                    if showsRichModules {
                        NavigationLink(value: HubModule.clock) {
                            Label("Clock", systemImage: "clock")
                        }

                        NavigationLink(value: HubModule.weather) {
                            Label("Weather", systemImage: "cloud.sun")
                        }
                    }
                }

                if !connection.isConnected {
                    Section {
                        Text("Open any module to preview it on screen. Connect a Pixoo 64 (Wi-Fi) to mirror it onto the device too.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Unofficial app — not affiliated with, authorized, or endorsed by Divoom. \u{201C}Divoom\u{201D} and \u{201C}Pixoo\u{201D} are trademarks of their respective owners.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PixelFlow")
            .navigationDestination(for: HubModule.self) { module in
                switch module {
                case .nowPlaying: NowPlayingView(connection: connection)
                case .clock: ClockFacesView(connection: connection)
                case .weather: WeatherView(connection: connection)
                }
            }
            .alert("Connect to Pixoo 64", isPresented: $showPixooIPPrompt) {
                TextField("192.168.1.42", text: $pixooIP)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") { connection.connectPixoo(host: pixooIP) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter your Pixoo's IP address. You'll find it in the Divoom app under the device's settings.")
            }
        }
        .task { connection.autoConnect() }
        .onChange(of: connection.isConnected) { _, connected in
            // Once the (auto-)connection comes up on launch, reopen the last-used module.
            if connected, !didResume, let module = HubModule(rawValue: lastModule) {
                didResume = true
                // Don't reopen a 64×64-only module (Clock/Weather) on a 16×16 Timebox.
                if module == .nowPlaying || connection.profile.width >= 64 { path = [module] }
            }
        }
        .onChange(of: path) { _, newPath in
            lastModule = newPath.last?.rawValue ?? ""   // remember where we are for next launch
        }
    }
}
