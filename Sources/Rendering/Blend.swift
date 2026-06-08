import Foundation
import TimeboxKit

/// Linear crossfade between two equally-sized surfaces.
enum Blend {
    /// `steps` intermediate surfaces from `a` toward `b`, ending exactly on `b`.
    /// If the two differ in size, returns `[b]` (nothing sensible to interpolate).
    static func crossfade(from a: Surface, to b: Surface, steps: Int) -> [Surface] {
        guard steps > 0, a.pixels.count == b.pixels.count else { return [b] }
        var frames: [Surface] = []
        frames.reserveCapacity(steps)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            var pixels = [PixelRGB]()
            pixels.reserveCapacity(a.pixels.count)
            for i in 0..<a.pixels.count {
                let ca = a.pixels[i], cb = b.pixels[i]
                pixels.append(PixelRGB(
                    red: lerp(ca.red, cb.red, t),
                    green: lerp(ca.green, cb.green, t),
                    blue: lerp(ca.blue, cb.blue, t)
                ))
            }
            frames.append(Surface(width: a.width, height: a.height, pixels: pixels) ?? b)
        }
        return frames
    }

    private static func lerp(_ a: UInt8, _ b: UInt8, _ t: Double) -> UInt8 {
        let value = Double(a) * (1 - t) + Double(b) * t
        return UInt8(max(0, min(255, value.rounded())))
    }

    // MARK: - Spectacular transitions

    enum Style: CaseIterable { case dissolve, wipe, slide, iris }

    /// `steps` frames animating `from` → `to` with a flashy effect (random style by default),
    /// ending exactly on `to`. Falls back to `[to]` on a size mismatch.
    static func transition(from a: Surface, to b: Surface, steps: Int, accent: PixelRGB,
                           style: Style = Style.allCases.randomElement() ?? .dissolve) -> [Surface] {
        guard steps > 0, a.width == b.width, a.height == b.height,
              a.pixels.count == b.pixels.count else { return [b] }
        switch style {
        case .dissolve: return dissolve(a, b, steps, accent)
        case .wipe:     return wipe(a, b, steps, accent)
        case .slide:    return slide(a, b, steps)
        case .iris:     return iris(a, b, steps, accent)
        }
    }

    private static func surface(_ w: Int, _ h: Int, _ px: [PixelRGB], _ fallback: Surface) -> Surface {
        Surface(width: w, height: h, pixels: px) ?? fallback
    }

    /// Sparkly per-pixel reveal: each pixel flips at its own random moment with a bright flash.
    private static func dissolve(_ a: Surface, _ b: Surface, _ steps: Int, _ accent: PixelRGB) -> [Surface] {
        let n = a.pixels.count
        let thr = (0..<n).map { _ in Double.random(in: 0...1) }
        let spark = Palette.mix(PixelRGB(red: 255, green: 255, blue: 255), Palette.vivid(accent), 0.4)
        var frames: [Surface] = []
        for s in 1...steps {
            if s == steps { frames.append(b); break }
            let t = Double(s) / Double(steps)
            var px = [PixelRGB](); px.reserveCapacity(n)
            for i in 0..<n {
                if abs(thr[i] - t) < 0.12 { px.append(spark) }
                else { px.append(thr[i] < t ? b.pixels[i] : a.pixels[i]) }
            }
            frames.append(surface(a.width, a.height, px, b))
        }
        return frames
    }

    /// Diagonal wipe with a bright accent leading edge.
    private static func wipe(_ a: Surface, _ b: Surface, _ steps: Int, _ accent: PixelRGB) -> [Surface] {
        let w = a.width, h = a.height, band = 7.0
        let edge = Palette.mix(PixelRGB(red: 255, green: 255, blue: 255), Palette.vivid(accent), 0.5)
        var frames: [Surface] = []
        for s in 1...steps {
            if s == steps { frames.append(b); break }
            let boundary = Double(s) / Double(steps) * (Double(w + h) + band)
            var px = [PixelRGB](); px.reserveCapacity(w * h)
            for y in 0..<h { for x in 0..<w {
                let d = Double(x + y)
                if d < boundary - band { px.append(b.at(x, y)) }
                else if d > boundary { px.append(a.at(x, y)) }
                else { px.append(edge) }
            }}
            frames.append(surface(w, h, px, b))
        }
        return frames
    }

    /// Push: the old frame slides off the left as the new one comes in from the right.
    private static func slide(_ a: Surface, _ b: Surface, _ steps: Int) -> [Surface] {
        let w = a.width, h = a.height
        var frames: [Surface] = []
        for s in 1...steps {
            if s == steps { frames.append(b); break }
            let off = Int((Double(s) / Double(steps) * Double(w)).rounded())
            var px = [PixelRGB](); px.reserveCapacity(w * h)
            for y in 0..<h { for x in 0..<w {
                px.append(x < w - off ? a.at(x + off, y) : b.at(x - (w - off), y))
            }}
            frames.append(surface(w, h, px, b))
        }
        return frames
    }

    /// Iris: the new frame expands from the center behind a bright accent ring.
    private static func iris(_ a: Surface, _ b: Surface, _ steps: Int, _ accent: PixelRGB) -> [Surface] {
        let w = a.width, h = a.height
        let cx = Double(w) / 2, cy = Double(h) / 2, band = 4.0
        let maxR = (cx * cx + cy * cy).squareRoot()
        let ring = Palette.mix(PixelRGB(red: 255, green: 255, blue: 255), Palette.vivid(accent), 0.5)
        var frames: [Surface] = []
        for s in 1...steps {
            if s == steps { frames.append(b); break }
            let r = Double(s) / Double(steps) * (maxR + band)
            var px = [PixelRGB](); px.reserveCapacity(w * h)
            for y in 0..<h { for x in 0..<w {
                let dx = Double(x) - cx + 0.5, dy = Double(y) - cy + 0.5
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist < r - band { px.append(b.at(x, y)) }
                else if dist > r { px.append(a.at(x, y)) }
                else { px.append(ring) }
            }}
            frames.append(surface(w, h, px, b))
        }
        return frames
    }
}
