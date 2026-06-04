import Foundation
import MediaPlayer
import UIKit

/// Album art + title from whatever is playing in the iPhone's Music app
/// (`MPMusicPlayerController.systemMusicPlayer`). Needs only Media & Apple Music
/// permission (NSAppleMusicUsageDescription) — no paid capability or portal setup.
@MainActor
final class MusicNowPlayingSource {
    struct Song {
        let title: String?
        let artist: String?
        let artwork: CGImage?
    }

    var onSong: ((Song) -> Void)?
    var onStatus: ((String) -> Void)?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var token: NSObjectProtocol?

    func start() {
        onStatus?("Requesting Apple Music access…")
        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.onStatus?("Apple Music access denied (Settings ▸ Privacy ▸ Media & Apple Music)")
                    return
                }
                self.player.beginGeneratingPlaybackNotifications()
                self.token = NotificationCenter.default.addObserver(
                    forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
                    object: self.player, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.update() }
                }
                self.onStatus?("Watching Apple Music…")
                self.update()
            }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token); self.token = nil }
        player.endGeneratingPlaybackNotifications()
    }

    private func update() {
        guard let item = player.nowPlayingItem else {
            onStatus?("Nothing playing in Apple Music")
            return
        }
        let art = item.artwork?.image(at: CGSize(width: 256, height: 256))?.cgImage
        onSong?(Song(title: item.title, artist: item.artist, artwork: art))
        onStatus?("Now playing")
    }
}
