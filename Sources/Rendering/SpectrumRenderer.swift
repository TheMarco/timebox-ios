import Foundation
import TimeboxKit

/// Draws a spectrum-analyzer bar graph along the bottom of a cover. `bands` are 0…1
/// magnitudes left→right; bars rise to at most `maxHeight` px. Each bar fades from the
/// album-art `accent` at its base to white near the peak, with a bright peak cap.
enum SpectrumRenderer {
    static func overlay(on cover: Surface, bands: [Float], accent: PixelRGB?, maxHeight: Int = 10) -> Surface {
        guard !bands.isEmpty, cover.width > 0 else { return cover }
        var s = cover
        let size = s.width
        let n = bands.count
        let acc = Palette.vivid(accent ?? PixelRGB(red: 90, green: 180, blue: 255))
        let peak = PixelRGB(red: 255, green: 255, blue: 255)

        // Dim a thin strip behind the bars so they read over busy covers.
        for y in max(0, size - maxHeight - 1)..<size {
            for x in 0..<size { s.set(x, y, Palette.darken(s.at(x, y), 0.45)) }
        }

        let barW = max(1, size / n)
        let gap = barW > 2 ? 1 : 0
        for i in 0..<n {
            let v = max(0, min(1, bands[i]))
            let h = Int((Float(maxHeight) * v).rounded())
            if h <= 0 { continue }
            let x0 = i * barW
            for dx in 0..<(barW - gap) {
                let x = x0 + dx
                if x >= size { break }
                for dy in 0..<h {
                    let t = Double(dy) / Double(max(1, maxHeight - 1))
                    let c = dy == h - 1 ? peak : Palette.mix(acc, peak, min(1, t * 1.3))
                    s.set(x, size - 1 - dy, c)
                }
            }
        }
        return s
    }
}
