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
            while let self, !Task.isCancelled {
                let result = await self.session.result()
                if Task.isCancelled { break }
                switch result {
                case .match(let match):
                    if let item = match.mediaItems.first {
                        self.onSong?(Song(title: item.title, artist: item.artist, artworkURL: item.artworkURL))
                        self.onStatus?("Matched")
                    }
                case .noMatch:
                    self.onStatus?("Listening… (no match yet)")
                case .error(let error, _):
                    self.onStatus?("Shazam unavailable: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
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
