import SwiftUI

struct NowPlayingView: View {
    @StateObject private var engine: NowPlayingEngine

    init(connection: TimeboxConnection) {
        _engine = StateObject(wrappedValue: NowPlayingEngine(connection: connection))
    }

    var body: some View {
        List {
            Section("Now playing") {
                Text(engine.nowPlaying).font(.callout)
                Text(engine.status).font(.caption).foregroundStyle(.secondary)
            }
            Section("Album art source") {
                Picker("Source", selection: $engine.artSource) {
                    ForEach(NowPlayingEngine.ArtSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Show on the Timebox") {
                Toggle("Album art", isOn: $engine.showAlbumArt)
                Picker("Clock", selection: $engine.clock) {
                    ForEach(NowPlayingEngine.ClockChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if engine.clock == .digital {
                Section {
                    Text("Digital clock shows 12-hour time on top and scrolls the full artist & title below, then fades to the cover. Its duration is automatic.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Album cover dwell") {
                HStack {
                    Text("Seconds")
                    Slider(value: $engine.dwellSeconds, in: 3...30, step: 1)
                    Text("\(Int(engine.dwellSeconds))s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Apple Music shows art for whatever's playing in the Music app (needs Media & Apple Music permission). Shazam IDs ambient music via the mic but needs the ShazamKit App ID capability (paid account). The clocks work regardless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Now Playing")
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }
}
