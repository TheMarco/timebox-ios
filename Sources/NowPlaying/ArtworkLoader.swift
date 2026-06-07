import Foundation
import UIKit
import TimeboxKit

/// Rasterizes album artwork to an enhanced `Surface` at the active device's resolution
/// (16×16 for the Timebox, 64×64 for the Pixoo).
enum ArtworkLoader {
    /// From a remote URL (Shazam artworkURL).
    static func surface(from url: URL, size: Int) async -> Surface? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let cgImage = UIImage(data: data)?.cgImage
        else { return nil }
        return surface(from: cgImage, size: size)
    }

    /// From a CGImage already in hand (Apple Music nowPlayingItem artwork).
    static func surface(from cgImage: CGImage, size: Int) -> Surface? {
        guard let surface = ImageToSurface.surface(from: cgImage, size: size, interpolation: .high)
        else { return nil }
        return ImageEnhance.punchUp(surface)
    }

    /// Look the cover up by title + artist via the public iTunes Search API and rasterize
    /// it. This is the fallback when a track has no embedded artwork (common for Apple
    /// Music streaming). No entitlement needed — just a web request.
    static func surface(title: String?, artist: String?, size: Int) async -> Surface? {
        guard let url = await searchArtworkURL(title: title, artist: artist) else { return nil }
        return await surface(from: url, size: size)
    }

    private static func searchArtworkURL(title: String?, artist: String?) async -> URL? {
        let term = [artist, title].compactMap { $0 }.joined(separator: " ")
        guard !term.isEmpty,
              let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(q)&entity=song&limit=1"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let art = results.first?["artworkUrl100"] as? String
        else { return nil }
        // Bump the resolution: the API returns a 100x100 URL we can resize via the path.
        return URL(string: art.replacingOccurrences(of: "100x100", with: "600x600"))
    }
}
