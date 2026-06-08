import Foundation
import TimeboxKit

/// Crossfade and a mosaic transition between two equally-sized surfaces.
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

    // MARK: - Mosaic transition

    /// `steps` frames animating `from` → `to` as a mosaic: `from` dissolves into ever-larger
    /// blocks, then `to` resolves back from large blocks down to full detail. Ends exactly on
    /// `to`. Falls back to `[to]` on a size mismatch.
    static func transition(from a: Surface, to b: Surface, steps: Int) -> [Surface] {
        guard steps >= 2, a.width == b.width, a.height == b.height,
              a.pixels.count == b.pixels.count else { return [b] }
        let maxCell = 16
        let half = steps / 2
        var frames: [Surface] = []
        for s in 1...steps {
            if s == steps { frames.append(b); break }
            if s <= half {                                  // pixelate `from`: blocks grow 1→max
                let cell = max(1, Int((Double(maxCell) * Double(s) / Double(half)).rounded()))
                frames.append(pixelate(a, cell: cell))
            } else {                                        // resolve `to`: blocks shrink max→1
                let frac = Double(s - half - 1) / Double(max(1, steps - half - 1))
                let cell = max(1, Int((Double(maxCell) * (1 - frac)).rounded()))
                frames.append(pixelate(b, cell: cell))
            }
        }
        return frames
    }

    /// Average each `cell`×`cell` block into a single color — a mosaic/pixelation of `s`.
    private static func pixelate(_ s: Surface, cell: Int) -> Surface {
        guard cell > 1 else { return s }
        let w = s.width, h = s.height
        var px = [PixelRGB](repeating: PixelRGB(red: 0, green: 0, blue: 0), count: w * h)
        var by = 0
        while by < h {
            var bx = 0
            while bx < w {
                let ey = min(by + cell, h), ex = min(bx + cell, w)
                var r = 0, g = 0, bl = 0, n = 0
                for yy in by..<ey { for xx in bx..<ex {
                    let c = s.at(xx, yy); r += Int(c.red); g += Int(c.green); bl += Int(c.blue); n += 1
                }}
                let avg = PixelRGB(red: UInt8(r / n), green: UInt8(g / n), blue: UInt8(bl / n))
                for yy in by..<ey { for xx in bx..<ex { px[yy * w + xx] = avg } }
                bx += cell
            }
            by += cell
        }
        return Surface(width: w, height: h, pixels: px) ?? s
    }
}
