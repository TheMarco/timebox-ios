import SwiftUI
import UIKit
import TimeboxKit

/// The "Now Playing" module: shows album art (Apple Music or Shazam) and/or one clock
/// (analog or digital), crossfading between them. The digital clock pins the time to the
/// top and scrolls the "Artist — Title" ticker below it.
///
/// Drives whichever display is connected via the shared `TimeboxConnection`: a 16×16
/// Timebox streamed frame-by-frame over BLE, or a 64×64 Pixoo 64 driven by its own engine
/// (static frames + native scrolling text + brightness fades) over Wi-Fi. Per-device
/// timing/geometry comes from the connection's `DisplayProfile`, so one module serves both.
@MainActor
final class NowPlayingEngine: ObservableObject {
    enum ArtSource: String, CaseIterable, Identifiable {
        case appleMusic = "Apple Music"
        case shazam = "Shazam"
        var id: String { rawValue }
    }

    enum ClockChoice: String, CaseIterable, Identifiable {
        case off = "Off"
        case analog = "Analog"
        case digital = "Digital"
        var id: String { rawValue }
    }

    /// How the Pixoo displays: the app-rendered Now Playing views, or the device's own
    /// built-in audio visualizer (snappy, full-screen, drawn by the Pixoo itself).
    enum DisplayMode: String, CaseIterable, Identifiable {
        case nowPlaying = "Now Playing"
        case visualizer = "Visualizer"
        var id: String { rawValue }
    }

    @Published var displayMode: DisplayMode = .nowPlaying {
        didSet { persistSettings() }
    }
    @Published var visualizerStyle = 0 {
        didSet {
            persistSettings()
            if running, displayMode == .visualizer, let pixoo = connection.backend as? PixooBackend {
                Task { try? await pixoo.showVisualizer(style: visualizerStyle) }
            }
        }
    }
    @Published var showAlbumArt = true { didSet { persistSettings() } }
    @Published var clock: ClockChoice = .digital { didSet { persistSettings() } }
    @Published var dwellSeconds: Double = 12 { didSet { persistSettings() } }
    @Published var artSource: ArtSource = .appleMusic {
        didSet {
            persistSettings()
            if running, oldValue != artSource { restartSource() }
        }
    }
    @Published var status = "Idle"
    @Published var nowPlaying = "—"
    @Published private(set) var running = false

    private enum Target { case albumArt, analog, digital }

    private let connection: TimeboxConnection
    private let shazam = ShazamRecognizer()
    private let music = MusicNowPlayingSource()
    private var artSurface: Surface?
    private var accentColor: PixelRGB?   // vivid color from the current cover; tints the 64×64 clocks + title
    private var artVersion = 0   // bumps on each new cover, so the loop re-sends it
    private var restartCycle = false  // new song: jump back to the cover before scrolling
    private var songKey = ""          // current track identity, to ignore repeat notifications
    private var isLoading = false     // suppresses persistence while restoring saved settings
    private var loop: Task<Void, Never>?

    /// The active panel's geometry/timing (16×16 Timebox or 64×64 Pixoo).
    private var profile: DisplayProfile { connection.profile }
    private var renderSize: Int { profile.width }
    /// True when connected to a Pixoo (it has a built-in visualizer); the Timebox doesn't.
    var supportsVisualizer: Bool { profile.drivesNatively }
    /// Album art used as the digital "hero" background — only when the user is showing art.
    private var digitalArt: Surface? { showAlbumArt ? artSurface : nil }

    init(connection: TimeboxConnection) {
        self.connection = connection
        loadSettings()
    }

    func start() {
        guard !running else { return }
        running = true
        // Keep the screen awake while the live display runs so the phone doesn't auto-sleep
        // and suspend us. (No background-audio keepalive — it crashes when another app, e.g.
        // Camera, seizes the audio session.)
        UIApplication.shared.isIdleTimerDisabled = true
        wireSources()
        startSource()
        // The Pixoo is driven by its own engine (static frames + native scrolling text +
        // brightness fades); the Timebox streams every frame over BLE.
        loop = Task { profile.drivesNatively ? await runNativeLoop() : await runLoop() }
    }

    func stop() {
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        loop?.cancel(); loop = nil
        music.stop()
        shazam.stop()
    }

    // MARK: - Settings persistence (restored on next launch)

    private enum Keys {
        static let artSource = "np.artSource", clock = "np.clock"
        static let showAlbumArt = "np.showAlbumArt", dwell = "np.dwell"
        static let displayMode = "np.displayMode", vizStyle = "np.vizStyle"
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        isLoading = true
        if let raw = d.string(forKey: Keys.artSource), let v = ArtSource(rawValue: raw) { artSource = v }
        if let raw = d.string(forKey: Keys.clock), let v = ClockChoice(rawValue: raw) { clock = v }
        if d.object(forKey: Keys.showAlbumArt) != nil { showAlbumArt = d.bool(forKey: Keys.showAlbumArt) }
        if d.object(forKey: Keys.dwell) != nil { dwellSeconds = d.double(forKey: Keys.dwell) }
        if let raw = d.string(forKey: Keys.displayMode), let v = DisplayMode(rawValue: raw) { displayMode = v }
        if d.object(forKey: Keys.vizStyle) != nil { visualizerStyle = d.integer(forKey: Keys.vizStyle) }
        isLoading = false
    }

    private func persistSettings() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        d.set(artSource.rawValue, forKey: Keys.artSource)
        d.set(clock.rawValue, forKey: Keys.clock)
        d.set(showAlbumArt, forKey: Keys.showAlbumArt)
        d.set(dwellSeconds, forKey: Keys.dwell)
        d.set(displayMode.rawValue, forKey: Keys.displayMode)
        d.set(visualizerStyle, forKey: Keys.vizStyle)
    }

    // MARK: - Art sources

    private func startSource() {
        switch artSource {
        case .appleMusic: music.start()
        case .shazam: shazam.start()
        }
    }

    private func restartSource() {
        music.stop(); shazam.stop()
        artSurface = nil
        accentColor = nil
        nowPlaying = "—"
        songKey = ""
        startSource()
    }

    private func setSong(title: String?, artist: String?) {
        nowPlaying = [artist, title].compactMap { $0 }.joined(separator: " — ")
    }

    private func wireSources() {
        music.onStatus = { [weak self] text in self?.status = text }
        music.onSong = { [weak self] song in
            guard let self else { return }
            let key = [song.artist, song.title].compactMap { $0 }.joined(separator: "|")
            guard key != self.songKey else { return }   // repeat notification for the same song
            self.songKey = key
            self.setSong(title: song.title, artist: song.artist)
            let size = self.renderSize
            if let cg = song.artwork, let art = ArtworkLoader.surface(from: cg, size: size) {
                self.setArt(art)
            } else {
                // No embedded artwork (Apple Music streaming) — look it up by title+artist.
                let title = song.title, artist = song.artist
                Task { [weak self] in
                    if let art = await ArtworkLoader.surface(title: title, artist: artist, size: size) { self?.setArt(art) }
                }
            }
        }
        shazam.onStatus = { [weak self] text in self?.status = text }
        shazam.onSong = { [weak self] song in
            guard let self else { return }
            let key = [song.artist, song.title].compactMap { $0 }.joined(separator: "|")
            guard key != self.songKey else { return }   // same song still playing
            self.songKey = key
            self.setSong(title: song.title, artist: song.artist)
            let size = self.renderSize
            guard let url = song.artworkURL else { return }
            Task { [weak self] in
                if let art = await ArtworkLoader.surface(from: url, size: size) { self?.setArt(art) }
            }
        }
    }

    /// Store the latest cover; the render loop re-sends it on the next tick (artVersion bump).
    private func setArt(_ surface: Surface) {
        artSurface = surface
        accentColor = Palette.accent(from: surface)   // derive a tint for the clocks + title
        artVersion += 1
        restartCycle = true     // new cover → show it first, then scroll the title
    }

    // MARK: - Render targets

    private func targets() -> [Target] {
        var list: [Target] = []
        if showAlbumArt, artSurface != nil { list.append(.albumArt) }
        switch clock {
        case .analog: list.append(.analog)
        case .digital: list.append(.digital)
        case .off: break
        }
        return list
    }

    private func tickerText() -> String { nowPlaying == "—" ? "" : nowPlaying }

    /// Song progress 0…1 for the bottom bar (Apple Music only; Shazam has no position).
    private func playbackProgress() -> Double? { artSource == .appleMusic ? music.progress : nil }

    private func render(_ target: Target, scroll: Int) -> Surface {
        switch target {
        case .albumArt: return artSurface ?? ClockRenderer.surface(for: Date(), size: renderSize)
        case .analog: return ClockRenderer.surface(for: Date(), size: renderSize, accent: accentColor)
        case .digital: return DigitalClockRenderer.surface(
            for: Date(), ticker: tickerText(), scroll: scroll,
            size: renderSize, tickerScale: profile.tickerScale, accent: accentColor, art: digitalArt)
        }
    }

    /// How far the ticker must scroll before it's fully off the left edge (device pixels).
    private func tickerSpan(_ text: String) -> Int {
        DigitalClockRenderer.tickerSpan(for: text, size: renderSize, tickerScale: profile.tickerScale)
    }

    // MARK: - Streaming render loop (Timebox / BLE)

    private func runLoop() async {
        let clock = ContinuousClock()
        var next = clock.now
        var lastFrame: Surface?
        var index = 0
        var elapsed = 0.0
        var scroll = 0
        var lastSecond = -1
        var lastArtVersion = artVersion

        while running && !Task.isCancelled {
            if !connection.isConnected {             // dropped: wait for the auto-reconnect
                status = "Reconnecting…"
                lastFrame = nil
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                next = clock.now
                continue
            }
            let items = targets()
            guard !items.isEmpty else {
                await sendSafely(ClockRenderer.surface(for: Date(), size: renderSize), last: &lastFrame)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                next = clock.now
                continue
            }
            if restartCycle {
                restartCycle = false
                index = 0; elapsed = 0; scroll = 0   // new song: cover first, then scroll
            }
            if index >= items.count { index = 0; elapsed = 0; scroll = 0 }
            let target = items[index]
            let entering = elapsed == 0
            let frame = render(target, scroll: scroll)

            if entering {
                if let from = lastFrame, from.width == frame.width, from.height == frame.height {
                    for f in Blend.crossfade(from: from, to: frame, steps: profile.crossfadeSteps) {
                        if !running { break }
                        await sendSafely(f, last: &lastFrame)
                        if profile.crossfadeStepDelay > 0 {
                            try? await Task.sleep(nanoseconds: profile.crossfadeStepDelay)
                        }
                    }
                } else {
                    await sendSafely(frame, last: &lastFrame)
                }
                lastSecond = Calendar.current.component(.second, from: Date())
                lastArtVersion = artVersion
            } else {
                // Digital scrolls every tick; analog refreshes per second; art is sent only
                // when a new cover arrives (keeps BLE near-silent so it coexists with audio).
                var send = false
                switch target {
                case .digital:
                    send = true
                case .analog:
                    let sec = Calendar.current.component(.second, from: Date())
                    if sec != lastSecond { send = true; lastSecond = sec }
                case .albumArt:
                    if artVersion != lastArtVersion { send = true; lastArtVersion = artVersion }
                }
                if send { await sendSafely(frame, last: &lastFrame) }
            }

            // Steady, deadline-based pacing: absorb variable send time so frame
            // intervals stay even (less stutter than a fixed sleep after each send).
            next = next.advanced(by: .seconds(profile.tick))
            if next < clock.now { next = clock.now }
            try? await clock.sleep(until: next, tolerance: .zero)
            elapsed += profile.tick
            // Digital scrolls the title in from the right and off the left.
            if target == .digital { scroll += profile.scrollStep }

            // The digital clock's dwell is dynamic: it ends once the full title has
            // scrolled away. The cover (and analog) use the dwell slider.
            let done: Bool
            switch target {
            case .digital:
                let text = tickerText()
                done = !text.isEmpty && scroll >= tickerSpan(text)
            case .albumArt, .analog:
                done = elapsed >= max(2.0, dwellSeconds)
            }
            if done {
                if items.count > 1 {
                    elapsed = 0; scroll = 0
                    index = (index + 1) % max(1, targets().count)
                } else if target == .digital {
                    elapsed = 0; scroll = 0   // only the clock showing: loop the ticker
                }
            }
        }
    }

    private func sendSafely(_ frame: Surface, last lastFrame: inout Surface?) async {
        do {
            try await connection.send(frame)
            lastFrame = frame
        } catch {
            // Transient drop — the transport auto-reconnects and the loop pauses (via the
            // isConnected check) until it's back. Keep the module running.
            lastFrame = nil
        }
    }

    // MARK: - Native render loop (Pixoo)

    private func clockMinute() -> Int { Calendar.current.component(.minute, from: Date()) }

    /// The Pixoo can't stream frames smoothly, so each view fades in through black, then the
    /// loop refreshes only live content. The digital view scrolls its title with the device's
    /// own text engine, then advances to the cover.
    private func runNativeLoop() async {
        guard let pixoo = connection.backend as? PixooBackend else { return }
        await pixoo.clearText()   // wipe any stale native scrolling text from a prior session

        while running && !Task.isCancelled {
            if !connection.isConnected {
                status = "Reconnecting…"
                await connection.attemptReconnect()
                if !connection.isConnected { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                continue
            }

            if displayMode == .visualizer {          // hand off to the device's own visualizer
                try? await pixoo.showVisualizer(style: visualizerStyle)
                status = "Visualizer"
                while running && !Task.isCancelled && connection.isConnected && displayMode == .visualizer {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                continue                             // back to Now Playing: the loop resumes streaming frames
            }

            let items = targets()
            if items.isEmpty {                       // nothing selected: just show the clock
                try? await pixoo.present(ClockRenderer.surface(for: Date(), size: renderSize), fade: false)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            if restartCycle { restartCycle = false }

            var index = 0
            // Re-evaluate the (possibly changed) target list each cycle.
            while running && !Task.isCancelled && connection.isConnected && displayMode == .nowPlaying {
                let live = targets()
                if live.isEmpty || restartCycle { break }
                index %= live.count
                let target = live[index]
                let multi = live.count > 1

                switch target {
                case .digital: await presentDigital(on: pixoo, multi: multi)
                case .analog:  await presentAnalog(on: pixoo, multi: multi)
                case .albumArt: await presentCover(on: pixoo, multi: multi)
                }

                if multi { index += 1 }              // single target: re-enter (re-scroll / refresh)
            }
        }
    }

    /// Shared loop guard for a dwelling view.
    private var nativeLoopAlive: Bool {
        running && !Task.isCancelled && connection.isConnected && displayMode == .nowPlaying && !restartCycle
    }

    /// Digital: fade in the hero card (clock over the cover or synthwave) with the title band
    /// blank (title parked off the right edge), then render the title scrolling fully in and
    /// back off the left exactly once — we own `scroll`, so it's a clean single pass: empty →
    /// in → out → empty. Then return so the loop hands off to the cover. No song: hold the clock.
    private func presentDigital(on pixoo: PixooBackend, multi: Bool) async {
        let title = tickerText()
        var scroll = 0
        func frame() -> Surface {
            DigitalClockRenderer.surface(for: Date(), ticker: title, scroll: scroll,
                                         size: renderSize, tickerScale: profile.tickerScale,
                                         accent: accentColor, art: digitalArt, progress: playbackProgress())
        }
        try? await pixoo.present(frame(), fade: true)   // enter: band blank, title off the right edge

        guard !title.isEmpty else {                     // no song: hold the clock, refresh per minute
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(max(4.0, dwellSeconds)))
            var lastMinute = clockMinute()
            while nativeLoopAlive {
                if clockMinute() != lastMinute { lastMinute = clockMinute(); try? await pixoo.present(frame(), fade: false) }
                if multi && clock.now >= deadline { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return
        }

        let span = tickerSpan(title)
        while nativeLoopAlive {
            scroll += profile.scrollStep
            try? await pixoo.present(frame(), fade: false)
            if scroll >= span {                         // one full pass: title fully off the left → empty
                if multi { return }                     // → back to the album cover
                scroll = 0                              // only the clock showing: loop the ticker
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Analog: fade in, then refresh ~once a second for the dwell.
    private func presentAnalog(on pixoo: PixooBackend, multi: Bool) async {
        func frame() -> Surface { ClockRenderer.surface(for: Date(), size: renderSize, accent: accentColor) }
        try? await pixoo.present(frame(), fade: true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(2.0, dwellSeconds)))
        while nativeLoopAlive {
            try? await pixoo.present(frame(), fade: false)
            if multi && clock.now >= deadline { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Album cover: fade in, then refresh periodically so the song-progress bar advances
    /// (and a new cover is picked up) over the dwell.
    private func presentCover(on pixoo: PixooBackend, multi: Bool) async {
        func coverFrame() -> Surface {
            var f = artSurface ?? ClockRenderer.surface(for: Date(), size: renderSize)
            if let p = playbackProgress() {
                DigitalClockRenderer.progressBar(into: &f, progress: p,
                    accent: Palette.vivid(accentColor ?? PixelRGB(red: 90, green: 180, blue: 255)))
            }
            return f
        }
        try? await pixoo.present(coverFrame(), fade: true)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(2.0, dwellSeconds)))
        var lastArtVersion = artVersion
        while nativeLoopAlive {
            // Re-send to advance the progress bar, or when a new cover arrives.
            if playbackProgress() != nil || artVersion != lastArtVersion {
                lastArtVersion = artVersion
                try? await pixoo.present(coverFrame(), fade: false)
            }
            if multi && clock.now >= deadline { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}
