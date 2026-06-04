import SwiftUI
import UIKit
import TimeboxKit

/// The "Now Playing" module: shows album art (Apple Music or Shazam) and/or one clock
/// (analog or digital), crossfading between them. The digital clock pins the time to
/// the top and scrolls the "Artist — Title" ticker below it.
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
    private var artFrame: PixelFrame?
    private var artVersion = 0   // bumps on each new cover, so the loop re-sends it
    private var restartCycle = false  // new song: jump back to the cover before scrolling
    private var songKey = ""          // current track identity, to ignore repeat notifications
    private var isLoading = false     // suppresses persistence while restoring saved settings
    private var loop: Task<Void, Never>?

    // The Timebox can't sustain fast full-frame streaming over BLE — push too hard and
    // its connection backs up and dies. ~5fps is sustainable indefinitely.
    private let tick = 0.2     // seconds per loop tick (~5fps)
    private let scrollStep = 2 // pixels the ticker advances per tick (higher = faster scroll)

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
        loop = Task { await runLoop() }
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
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        isLoading = true
        if let raw = d.string(forKey: Keys.artSource), let v = ArtSource(rawValue: raw) { artSource = v }
        if let raw = d.string(forKey: Keys.clock), let v = ClockChoice(rawValue: raw) { clock = v }
        if d.object(forKey: Keys.showAlbumArt) != nil { showAlbumArt = d.bool(forKey: Keys.showAlbumArt) }
        if d.object(forKey: Keys.dwell) != nil { dwellSeconds = d.double(forKey: Keys.dwell) }
        isLoading = false
    }

    private func persistSettings() {
        guard !isLoading else { return }
        let d = UserDefaults.standard
        d.set(artSource.rawValue, forKey: Keys.artSource)
        d.set(clock.rawValue, forKey: Keys.clock)
        d.set(showAlbumArt, forKey: Keys.showAlbumArt)
        d.set(dwellSeconds, forKey: Keys.dwell)
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
        artFrame = nil
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
            if let cg = song.artwork, let frame = ArtworkLoader.frame(from: cg) {
                self.setArt(frame)
            } else {
                // No embedded artwork (Apple Music streaming) — look it up by title+artist.
                let title = song.title, artist = song.artist
                Task { [weak self] in
                    if let frame = await ArtworkLoader.frame(title: title, artist: artist) { self?.setArt(frame) }
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
            guard let url = song.artworkURL else { return }
            Task { [weak self] in
                if let frame = await ArtworkLoader.frame(from: url) { self?.setArt(frame) }
            }
        }
    }

    /// Store the latest cover; the render loop re-sends it on the next tick (artVersion bump).
    private func setArt(_ frame: PixelFrame) {
        artFrame = frame
        artVersion += 1
        restartCycle = true     // new cover → show it first, then scroll the title
    }

    // MARK: - Render loop

    private func targets() -> [Target] {
        var list: [Target] = []
        if showAlbumArt, artFrame != nil { list.append(.albumArt) }
        switch clock {
        case .analog: list.append(.analog)
        case .digital: list.append(.digital)
        case .off: break
        }
        return list
    }

    private func tickerText() -> String { nowPlaying == "—" ? "" : nowPlaying }

    private func render(_ target: Target, scroll: Int) -> PixelFrame {
        switch target {
        case .albumArt: return artFrame ?? ClockRenderer.frame(for: Date())
        case .analog: return ClockRenderer.frame(for: Date())
        case .digital: return DigitalClockRenderer.frame(for: Date(), ticker: tickerText(), scroll: scroll)
        }
    }

    private func runLoop() async {
        let clock = ContinuousClock()
        var next = clock.now
        var lastFrame: PixelFrame?
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
                await sendSafely(ClockRenderer.frame(for: Date()), last: &lastFrame)
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
                if let from = lastFrame {
                    for f in Blend.crossfade(from: from, to: frame, steps: 6) {
                        if !running { break }
                        await sendSafely(f, last: &lastFrame)
                        try? await Task.sleep(nanoseconds: 40_000_000)
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
            next = next.advanced(by: .seconds(tick))
            if next < clock.now { next = clock.now }
            try? await clock.sleep(until: next, tolerance: .zero)
            elapsed += tick
            // Digital scrolls the title in from the right and off the left.
            if target == .digital { scroll += scrollStep }

            // The digital clock's dwell is dynamic: it ends once the full title has
            // scrolled away. The cover (and analog) use the dwell slider.
            let done: Bool
            switch target {
            case .digital:
                let text = tickerText()
                // Pass complete once it has fully entered from the right (+16) and exited left.
                done = !text.isEmpty && scroll >= PixelFont.columns(for: text).count + 16
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

    private func sendSafely(_ frame: PixelFrame, last lastFrame: inout PixelFrame?) async {
        do {
            try await connection.send(frame)
            lastFrame = frame
        } catch {
            // Transient drop — the transport auto-reconnects and the loop pauses (via the
            // isConnected check) until it's back. Keep the module running.
            lastFrame = nil
        }
    }
}
