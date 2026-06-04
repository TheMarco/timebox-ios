import Foundation
import ShazamKit

/// Continuously listens via the microphone and reports recognized songs.
///
/// Uses `SHManagedSession` (iOS 17+), which manages the audio capture for us.
/// Requires the **ShazamKit capability** (paid Apple Developer account) for catalog
/// access plus microphone permission. If the capability/permission is missing,
/// `result()` returns `.error`, which we surface as status text.
@MainActor
final class ShazamRecognizer {
    struct Song: Equatable {
        let title: String?
        let artist: String?
        let artworkURL: URL?
    }

    var onSong: ((Song) -> Void)?
    var onStatus: ((String) -> Void)?

    private let session = SHManagedSession()
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        onStatus?("Listening…")
        task = Task { [weak self] in
            var consecutiveErrors = 0
            while let self, !Task.isCancelled {
                let result = await self.session.result()
                if Task.isCancelled { break }
                switch result {
                case .match(let match):
                    consecutiveErrors = 0
                    if let item = match.mediaItems.first {
                        self.onSong?(Song(title: item.title, artist: item.artist, artworkURL: item.artworkURL))
                        self.onStatus?("Matched")
                    }
                case .noMatch:
                    consecutiveErrors = 0
                    self.onStatus?("Listening… (no match yet)")
                case .error(let error, _):
                    // `matchAttemptFailed` (202) is a normal, transient outcome of continuous
                    // matching — a momentary network blip or an audio window that didn't
                    // resolve. The session keeps listening and the next window usually matches,
                    // so don't surface it or stall: just loop and try again immediately.
                    if (error as? SHError)?.code == .matchAttemptFailed {
                        consecutiveErrors += 1
                        self.onStatus?("Listening…")
                        // Only back off if they're sustained (e.g. genuinely offline), to
                        // avoid hot-looping; a stray blip costs nothing.
                        if consecutiveErrors >= 5 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                    } else {
                        self.onStatus?("Shazam unavailable: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        session.cancel()
    }
}
