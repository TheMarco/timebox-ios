import SwiftUI
import UIKit

struct NowPlayingView: View {
    @StateObject private var engine: NowPlayingEngine
    @Environment(\.scenePhase) private var scenePhase

    // "Dim screen" keeps the app awake and the Timebox running, but drops the phone screen
    // to black + minimum backlight to save battery (true black = pixels off on OLED).
    @State private var dimmed = false
    @State private var savedBrightness = UIScreen.main.brightness

    init(connection: TimeboxConnection) {
        _engine = StateObject(wrappedValue: NowPlayingEngine(connection: connection))
    }

    var body: some View {
        List {
            Section("Now playing") {
                Text(engine.nowPlaying).font(.callout)
                Text(engine.status).font(.caption).foregroundStyle(.secondary)
            }

            if engine.supportsVisualizer {
                Section("Pixoo display") {
                    Picker("Mode", selection: $engine.displayMode) {
                        ForEach(NowPlayingEngine.DisplayMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if engine.displayMode == .visualizer {
                        Stepper("Visualizer style \(engine.visualizerStyle)", value: $engine.visualizerStyle, in: 0...11)
                    }
                }
                if engine.displayMode == .visualizer {
                    Section {
                        Text("The Pixoo's own built-in audio visualizer — snappy and full-screen, drawn by the device from its own microphone. Step through the styles to pick one. Switch back to Now Playing for album art + clocks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if engine.displayMode == .nowPlaying {
                Section("Album art source") {
                    Picker("Source", selection: $engine.artSource) {
                        ForEach(NowPlayingEngine.ArtSource.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Show on the device") {
                    Toggle("Album art", isOn: $engine.showAlbumArt)
                    Picker("Clock", selection: $engine.clock) {
                        ForEach(NowPlayingEngine.ClockChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Spectrum bars on cover", isOn: $engine.spectrumEnabled)
                }
                if engine.spectrumEnabled {
                    Section {
                        Text("Live audio spectrum over the album cover (Pixoo 64 only). It uses the phone's microphone, so it reacts to music playing out loud in the room — not through headphones — and streams at the device's ~5 fps. For a snappy full-screen version, use Visualizer mode above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if engine.clock == .digital {
                    Section {
                        Text("Digital clock shows the time with a scrolling artist & title below, then cycles to the cover. Its duration is automatic.")
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
            }

            Section {
                Button { dim() } label: {
                    Label("Dim screen (keep running, save battery)", systemImage: "moon.fill")
                }
                Text("Blacks out the phone screen while the Timebox keeps going. Tap the screen to wake. Leaving this screen restores brightness.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Apple Music shows art for whatever's playing in the Music app (needs Media & Apple Music permission). Shazam IDs ambient music via the mic but needs the ShazamKit App ID capability (paid account). The clocks work regardless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Now Playing")
        .onAppear { engine.start() }
        // Only stop when truly leaving the module — not when the dim cover is presented on top
        // (the engine must keep driving the Timebox while the phone screen is black).
        .onDisappear { if !dimmed { engine.stop() } }
        .onChange(of: scenePhase) { _, phase in
            // Keep it dark only while we're the active app; never leave the device's
            // brightness stuck low if the user switches away.
            if dimmed { UIScreen.main.brightness = (phase == .active) ? 0 : savedBrightness }
        }
        .fullScreenCover(isPresented: $dimmed, onDismiss: restoreBrightness) {
            ZStack {
                Color.black.ignoresSafeArea()
                Text("Tap to wake")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.18))
            }
            .contentShape(Rectangle())
            .onTapGesture { dimmed = false }
            .statusBarHidden()
        }
    }

    private func dim() {
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        dimmed = true
    }

    private func restoreBrightness() {
        UIScreen.main.brightness = savedBrightness
    }
}
