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
    /// Lo-fi pixel-art preset for the cover (`"Off"` or a `PixelArt` style id). Optional; the
    /// smooth enhanced cover is kept as `baseArt` so presets can be switched live.
    @Published var pixelStyleID = NowPlayingEngine.pixelArtOff {
        didSet { persistSettings(); if oldValue != pixelStyleID { applyArtStyle() } }
    }
    @Published var clock: ClockChoice = .digital { didSet { persistSettings() } }

    /// The "no treatment" sentinel, plus the full picker list (Off + every preset).
    static let pixelArtOff = "Off"
    var pixelStyleOptions: [String] { [Self.pixelArtOff] + PixelArt.presets.map(\.id) }
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
    private var baseArt: Surface?        // the smooth enhanced cover, before the optional pixel-art pass
    private var artSurface: Surface?     // what's actually shown (baseArt, possibly stylized)
    private var accentColor: PixelRGB?   // vivid color from the current cover; tints the 64×64 clocks + title
    private var artVersion = 0   // bumps on each new cover, so the loop re-sends it
    private var restartCycle = false  // new song: jump back to the cover before scrolling
    private var songKey = ""          // current track identity, to ignore repeat notifications
    private var isLoading = false     // suppresses persistence while restoring saved settings
    private var loop: Task<Void, Never>?
    private var previewLoop: Task<Void, Never>?

    /// A live render of what the panel is showing (cover ⇄ clock ⇄ title, with the active pixel-art
    /// mode applied), for the in-app `PixooFrame`. Held in its *own* observable rather than on the
    /// engine so the ~8 fps frame updates redraw only the preview view — not the whole settings
    /// form, whose constant invalidation was making the mode picker drop taps. Driven independently
    /// of the device link, so the preview works with Apple Music playing and nothing connected.
    let preview = PanelPreview()

    /// The active panel's geometry/timing (16×16 Timebox or 64×64 Pixoo).
    private var profile: DisplayProfile { connection.profile }
    private var renderSize: Int { profile.width }
    /// The device's built-in audio visualizer is a Pixoo-only, on-device feature — only offer it
    /// when actually connected (there's nothing to preview in-app without the hardware).
    var supportsVisualizer: Bool { connection.isConnected && profile.drivesNatively }

    /// True only while the panel is handed off to the device's own visualizer; in that one mode
    /// the app shows no preview (the Pixoo draws itself from its mic). Otherwise — including
    /// whenever no device is connected — we render the Now Playing preview.
    var showingDeviceVisualizer: Bool { supportsVisualizer && displayMode == .visualizer }
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
        previewLoop = Task { await runPreviewLoop() }
    }

    func stop() {
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        loop?.cancel(); loop = nil
        previewLoop?.cancel(); previewLoop = nil
        preview.surface = nil
        music.stop()
        shazam.stop()
    }

    // MARK: - Settings persistence (restored on next launch)

    private enum Keys {
        static let artSource = "np.artSource", clock = "np.clock"
        static let showAlbumArt = "np.showAlbumArt", dwell = "np.dwell"
        static let displayMode = "np.displayMode", vizStyle = "np.vizStyle"
        static let pixelStyle = "np.pixelStyle"
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        isLoading = true
        if let raw = d.string(forKey: Keys.artSource), let v = ArtSource(rawValue: raw) { artSource = v }
        if let raw = d.string(forKey: Keys.clock), let v = ClockChoice(rawValue: raw) { clock = v }
        if d.object(forKey: Keys.showAlbumArt) != nil { showAlbumArt = d.bool(forKey: Keys.showAlbumArt) }
        if let raw = d.string(forKey: Keys.pixelStyle),
           raw == Self.pixelArtOff || PixelArt.preset(named: raw) != nil { pixelStyleID = raw }
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
        d.set(pixelStyleID, forKey: Keys.pixelStyle)
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
        baseArt = nil
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
        baseArt = surface
        applyArtStyle(restart: true)   // new cover → show it first, then scroll the title
    }

    /// (Re)derive the shown cover from `baseArt`, applying the pixel-art pass when enabled, and
    /// refresh the accent tint. Called on a new cover and whenever the `pixelArt` toggle flips.
    private func applyArtStyle(restart: Bool = false) {
        guard let base = baseArt else { return }
        let styled = PixelArt.preset(named: pixelStyleID).map { PixelArt.stylize(base, style: $0) } ?? base
        artSurface = styled
        accentColor = Palette.accent(from: styled)   // derive a tint for the clocks + title
        artVersion += 1                               // loops re-send the cover on the next tick
        if restart { restartCycle = true }
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

    // MARK: - In-app preview loop

    /// Drives `previewSurface` with the same cover ⇄ clock cycle the device shows, rendered fully
    /// in-Surface (including the scrolling title) so the app's `PixooFrame` is a faithful, always-on
    /// picture of the panel — decoupled from the hardware. Active only in Now Playing mode.
    private func runPreviewLoop() async {
        let clock = ContinuousClock()
        var index = 0, scroll = 0, elapsed = 0.0
        var lastSong = ""
        while running && !Task.isCancelled {
            guard !showingDeviceVisualizer else {           // visualizer: the device draws itself
                preview.surface = nil
                try? await clock.sleep(for: .seconds(0.3)); continue
            }
            let items = targets()
            guard !items.isEmpty else {                    // nothing selected: just the clock
                let size = renderSize
                preview.surface = await Task.detached { ClockRenderer.surface(for: Date(), size: size) }.value
                try? await clock.sleep(for: .seconds(0.5)); continue
            }
            if songKey != lastSong { lastSong = songKey; index = 0; scroll = 0; elapsed = 0 }  // new song → cover first
            index %= items.count
            let target = items[index]
            preview.surface = await previewFrame(target, scroll: scroll)

            try? await clock.sleep(for: .seconds(0.12))
            elapsed += 0.12
            if target == .digital { scroll += profile.scrollStep }

            let done: Bool
            switch target {
            case .digital:
                let text = tickerText()
                done = !text.isEmpty && scroll >= tickerSpan(text)
            case .albumArt, .analog:
                done = elapsed >= max(2.0, dwellSeconds)
            }
            if done {
                elapsed = 0; scroll = 0
                if items.count > 1 { index = (index + 1) % items.count }
            }
        }
    }

    /// Render one preview frame off the main thread (mirrors the Pixoo presenters).
    private func previewFrame(_ target: Target, scroll: Int) async -> Surface {
        let size = renderSize, scale = profile.tickerScale
        let acc = accentColor, art = digitalArt, cover = artSurface
        let title = tickerText(), prog = playbackProgress()
        switch target {
        case .albumArt:
            return await Task.detached {
                var f = cover ?? ClockRenderer.surface(for: Date(), size: size)
                if let p = prog { DigitalClockRenderer.progressReveal(into: &f, progress: p) }
                return f
            }.value
        case .analog:
            return await Task.detached { ClockRenderer.surface(for: Date(), size: size, accent: acc, art: art) }.value
        case .digital:
            return await Task.detached {
                DigitalClockRenderer.surface(for: Date(), ticker: title, scroll: scroll, size: size,
                                             tickerScale: scale, accent: acc, art: art, progress: prog)
            }.value
        }
    }

    // MARK: - Native render loop (Pixoo)

    private func clockMinute() -> Int { Calendar.current.component(.minute, from: Date()) }

    /// The last full frame pushed to the Pixoo, so a view change can animate a transition from
    /// it instead of a plain brightness fade.
    private var lastShown: Surface?

    /// Enter a view: a flashy frame-based transition from whatever's on screen (random style),
    /// or a brightness fade when we don't know the outgoing frame.
    private func enter(_ pixoo: PixooBackend, _ frame: Surface) async {
        if let from = lastShown, from.width == frame.width, from.height == frame.height {
            // Build the mosaic transition off the main thread — on the Pixoo it's a 64×64
            // pixelate burst that would otherwise stall the UI (and the navigation pop).
            let frames = await Task.detached { Blend.transition(from: from, to: frame, steps: 8) }.value
            for f in frames {
                if !nativeLoopAlive { break }
                try? await pixoo.present(f, fade: false)
            }
        } else {
            try? await pixoo.present(frame, fade: true)
        }
        lastShown = frame
    }

    /// Push a live-refresh frame (no transition) and remember it as the last shown.
    private func show(_ pixoo: PixooBackend, _ frame: Surface) async {
        try? await pixoo.present(frame, fade: false)
        lastShown = frame
    }

    /// The Pixoo can't stream frames smoothly, so each view fades in through black, then the
    /// loop refreshes only live content. The digital view scrolls its title with the device's
    /// own text engine, then advances to the cover.
    private func runNativeLoop() async {
        guard let pixoo = connection.backend as? PixooBackend else { return }
        await pixoo.clearText()   // wipe any stale native scrolling text from a prior session
        lastShown = nil

        while running && !Task.isCancelled {
            if !connection.isConnected {
                status = "Reconnecting…"
                lastShown = nil
                await connection.attemptReconnect()
                if !connection.isConnected { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                continue
            }

            if displayMode == .visualizer {          // hand off to the device's own visualizer
                lastShown = nil                      // device draws its own channel now
                try? await pixoo.showVisualizer(style: visualizerStyle)
                status = "Visualizer"
                while running && !Task.isCancelled && connection.isConnected && displayMode == .visualizer {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                continue                             // back to Now Playing: the loop resumes streaming frames
            }

            let items = targets()
            if items.isEmpty {                       // nothing selected: just show the clock
                let size = renderSize
                let clk = await Task.detached { ClockRenderer.surface(for: Date(), size: size) }.value
                await show(pixoo, clk)
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
        let size = renderSize, scale = profile.tickerScale
        var scroll = 0
        func frame() async -> Surface {
            let acc = accentColor, art = digitalArt, prog = playbackProgress(), sc = scroll
            return await Task.detached {
                DigitalClockRenderer.surface(for: Date(), ticker: title, scroll: sc,
                                             size: size, tickerScale: scale,
                                             accent: acc, art: art, progress: prog)
            }.value
        }
        await enter(pixoo, await frame())               // enter: band blank, title off the right edge

        guard !title.isEmpty else {                     // no song: hold the clock, refresh per minute
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(max(4.0, dwellSeconds)))
            var lastMinute = clockMinute()
            while nativeLoopAlive {
                if clockMinute() != lastMinute { lastMinute = clockMinute(); await show(pixoo, await frame()) }
                if multi && clock.now >= deadline { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return
        }

        let span = tickerSpan(title)
        while nativeLoopAlive {
            scroll += profile.scrollStep
            await show(pixoo, await frame())
            if scroll >= span {                         // one full pass: title fully off the left → empty
                if multi { return }                     // → back to the album cover
                scroll = 0                              // only the clock showing: loop the ticker
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Analog: fade in, then refresh ~once a second for the dwell.
    private func presentAnalog(on pixoo: PixooBackend, multi: Bool) async {
        let size = renderSize
        func frame() async -> Surface {
            let acc = accentColor, art = digitalArt
            return await Task.detached { ClockRenderer.surface(for: Date(), size: size, accent: acc, art: art) }.value
        }
        await enter(pixoo, await frame())
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(2.0, dwellSeconds)))
        while nativeLoopAlive {
            await show(pixoo, await frame())
            if multi && clock.now >= deadline { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Album cover: fade in, then refresh periodically so the song-progress bar advances
    /// (and a new cover is picked up) over the dwell.
    private func presentCover(on pixoo: PixooBackend, multi: Bool) async {
        let size = renderSize
        func coverFrame() async -> Surface {
            let art = artSurface, prog = playbackProgress()
            return await Task.detached {
                var f = art ?? ClockRenderer.surface(for: Date(), size: size)
                if let p = prog { DigitalClockRenderer.progressReveal(into: &f, progress: p) }
                return f
            }.value
        }
        await enter(pixoo, await coverFrame())
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(2.0, dwellSeconds)))
        var lastArtVersion = artVersion
        while nativeLoopAlive {
            // Re-send to advance the progress reveal, or when a new cover arrives.
            if playbackProgress() != nil || artVersion != lastArtVersion {
                lastArtVersion = artVersion
                await show(pixoo, await coverFrame())
            }
            if multi && clock.now >= deadline { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}

/// Holds just the live preview frame, separate from `NowPlayingEngine` so its high-frequency
/// updates redraw only the preview view — keeping the surrounding settings form (and its mode
/// picker) responsive.
@MainActor
final class PanelPreview: ObservableObject {
    @Published var surface: Surface?
}
