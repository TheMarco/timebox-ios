import Foundation
import TimeboxKit

/// Turns an album cover into deliberately lo-fi, retro-graphics pixel art *without* throwing
/// away spatial resolution — every pixel of the 16×16 / 64×64 surface stays distinct. The look
/// comes from colour, not blockiness:
///
///   1. a reduced palette — either *adaptive* (median cut, pulled from the cover itself so each
///      album keeps its own hues) or a *fixed* retro-console set (Game Boy, PICO-8, …); and
///   2. 8×8 ordered (Bayer) dithering — the cross-hatch texture that lets a tiny palette read as
///      far richer, and is the signature lo-fi console look. At 64×64 there are plenty of pixels
///      to carry the pattern.
///
/// Pure `Surface → Surface`, like `ImageEnhance.punchUp`, applied as an *optional* pass driven by
/// a named `Style`. The engine keeps the un-stylized cover around so styles can be switched live.
enum PixelArt {
    /// A named preset: where the palette comes from, and how hard to dither.
    struct Style: Identifiable {
        let id: String                 // also the UI label and the persisted key
        let palette: PaletteSource
        let dither: Double             // 0 = banded, ~0.5 = balanced, 1 = heavy cross-hatch
    }

    enum PaletteSource {
        case adaptive(colors: Int)     // median-cut from the cover
        case fixed([PixelRGB])         // a fixed console palette (nearest-colour match)
        case ramp([PixelRGB])          // a dark→light monochrome/CRT ramp (luminance-mapped)
    }

    /// The preset catalogue, in the order shown in the UI. Adaptive looks keep each cover's own
    /// colours; the console palettes impose a strong shared identity.
    static let presets: [Style] = [
        // Adaptive — keep each album's own colours.
        Style(id: "Soft",       palette: .adaptive(colors: 24), dither: 0.35),
        Style(id: "Classic",    palette: .adaptive(colors: 16), dither: 0.50),
        Style(id: "Crunchy",    palette: .adaptive(colors: 8),  dither: 0.90),
        // Fixed console palettes — a strong shared identity.
        Style(id: "Game Boy",   palette: .fixed(gameBoy),       dither: 0.80),
        Style(id: "PICO-8",     palette: .fixed(pico8),         dither: 0.55),
        Style(id: "C64",        palette: .fixed(c64),           dither: 0.55),
        Style(id: "NES",        palette: .fixed(nes),           dither: 0.45),
        Style(id: "ZX Spectrum",palette: .fixed(zxSpectrum),    dither: 0.70),
        Style(id: "CGA",        palette: .fixed(cga),           dither: 1.00),
        Style(id: "Vaporwave",  palette: .fixed(vaporwave),     dither: 0.60),
        Style(id: "1-bit",      palette: .fixed(oneBit),        dither: 1.00),
        // Monochrome / CRT ramps — luminance-mapped.
        Style(id: "Mono",       palette: .ramp(mono),           dither: 1.00),
        Style(id: "Sepia",      palette: .ramp(sepia),          dither: 0.90),
        Style(id: "Green CRT",  palette: .ramp(greenCRT),       dither: 0.90),
        Style(id: "Amber CRT",  palette: .ramp(amberCRT),       dither: 0.90),
        Style(id: "Virtual Boy",palette: .ramp(virtualBoy),     dither: 1.00),
        Style(id: "Thermal",    palette: .ramp(thermal),        dither: 0.70),
    ]

    static func preset(named id: String) -> Style? { presets.first { $0.id == id } }

    /// Apply a preset. Builds the palette (adaptive or fixed), then quantizes every pixel to it
    /// with ordered dithering.
    static func stylize(_ surface: Surface, style: Style) -> Surface {
        switch style.palette {
        case .adaptive(let n): return quantize(surface, to: medianCut(surface.pixels, into: max(2, n)), dither: style.dither)
        case .fixed(let p):    return quantize(surface, to: p, dither: style.dither)
        case .ramp(let r):     return rampMap(surface, ramp: r, dither: style.dither)
        }
    }

    /// Luminance-map each pixel onto a dark→light ramp with ordered dithering between the two
    /// nearest steps. This gives true monochrome/duotone looks (sepia, phosphor CRT, Virtual Boy)
    /// and false-colour ramps (thermal) where a flat nearest-RGB match would misbehave.
    private static func rampMap(_ surface: Surface, ramp: [PixelRGB], dither: Double) -> Surface {
        guard ramp.count > 1 else { return surface }
        let n = ramp.count
        var out = surface.pixels
        for y in 0..<surface.height {
            for x in 0..<surface.width {
                let i = y * surface.width + x
                let l = luma(surface.pixels[i])                       // 0…1 brightness
                let pos = l * Double(n - 1) + (bayer8[y & 7][x & 7] - 0.5) * dither
                out[i] = ramp[max(0, min(n - 1, Int(pos.rounded())))]
            }
        }
        return Surface(width: surface.width, height: surface.height, pixels: out) ?? surface
    }

    private static func luma(_ p: PixelRGB) -> Double {
        (0.299 * Double(p.red) + 0.587 * Double(p.green) + 0.114 * Double(p.blue)) / 255.0
    }

    // MARK: - Quantize + dither

    private static func quantize(_ surface: Surface, to palette: [PixelRGB], dither: Double) -> Surface {
        guard palette.count > 1 else { return surface }
        // Dither amplitude ≈ the typical spacing between palette entries, so a pixel sitting
        // between two colours gets nudged across the boundary in a stable cross-hatch rather than
        // turning to noise. Self-tuning: a tight palette dithers gently, a sparse one (1-bit, CGA)
        // strongly.
        let amp = dither * averageNearestDistance(palette)
        var out = surface.pixels
        for y in 0..<surface.height {
            for x in 0..<surface.width {
                let i = y * surface.width + x
                let p = surface.pixels[i]
                let t = (bayer8[y & 7][x & 7] - 0.5) * amp   // ordered offset, ≈ ±amp/2
                out[i] = nearest(in: palette,
                                 r: clampByte(Double(p.red) + t),
                                 g: clampByte(Double(p.green) + t),
                                 b: clampByte(Double(p.blue) + t))
            }
        }
        return Surface(width: surface.width, height: surface.height, pixels: out) ?? surface
    }

    // MARK: - Median-cut adaptive palette

    /// Recursively split the colour cloud into `count` boxes along each box's widest channel,
    /// then average each box. Cheap and order-independent — runs once per new cover.
    private static func medianCut(_ pixels: [PixelRGB], into count: Int) -> [PixelRGB] {
        guard !pixels.isEmpty else { return [] }
        var boxes = [pixels]
        while boxes.count < count {
            guard let idx = widestBoxIndex(boxes) else { break }   // nothing left to split
            let channel = widestChannel(boxes[idx])
            let sorted = boxes[idx].sorted { component($0, channel) < component($1, channel) }
            let mid = sorted.count / 2
            boxes[idx] = Array(sorted[..<mid])
            boxes.append(Array(sorted[mid...]))
        }
        return boxes.compactMap(average)
    }

    /// Index of the box with the largest single-channel spread (and >1 pixel, so it can split).
    private static func widestBoxIndex(_ boxes: [[PixelRGB]]) -> Int? {
        var best: Int?
        var bestRange = 0
        for (i, box) in boxes.enumerated() where box.count > 1 {
            let r = channelRange(box)
            if best == nil || r > bestRange { best = i; bestRange = r }
        }
        return best
    }

    private static func bounds(_ box: [PixelRGB]) -> (lo: [Int], hi: [Int]) {
        var lo = [255, 255, 255], hi = [0, 0, 0]
        for p in box {
            let c = [Int(p.red), Int(p.green), Int(p.blue)]
            for k in 0..<3 { lo[k] = min(lo[k], c[k]); hi[k] = max(hi[k], c[k]) }
        }
        return (lo, hi)
    }

    private static func channelRange(_ box: [PixelRGB]) -> Int {
        let (lo, hi) = bounds(box)
        return max(hi[0] - lo[0], max(hi[1] - lo[1], hi[2] - lo[2]))
    }

    private static func widestChannel(_ box: [PixelRGB]) -> Int {
        let (lo, hi) = bounds(box)
        let r = [hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]]
        var best = 0
        for k in 1..<3 where r[k] > r[best] { best = k }
        return best
    }

    private static func component(_ p: PixelRGB, _ ch: Int) -> UInt8 {
        ch == 0 ? p.red : (ch == 1 ? p.green : p.blue)
    }

    private static func average(_ box: [PixelRGB]) -> PixelRGB? {
        guard !box.isEmpty else { return nil }
        var r = 0, g = 0, b = 0
        for p in box { r += Int(p.red); g += Int(p.green); b += Int(p.blue) }
        let n = box.count
        return PixelRGB(red: UInt8(r / n), green: UInt8(g / n), blue: UInt8(b / n))
    }

    // MARK: - Quantization helpers

    /// Nearest palette colour by squared RGB distance.
    private static func nearest(in palette: [PixelRGB], r: UInt8, g: UInt8, b: UInt8) -> PixelRGB {
        let R = Int(r), G = Int(g), B = Int(b)
        var best = palette[0], bestD = Int.max
        for c in palette {
            let dr = R - Int(c.red), dg = G - Int(c.green), db = B - Int(c.blue)
            let d = dr * dr + dg * dg + db * db
            if d < bestD { bestD = d; best = c }
        }
        return best
    }

    /// Mean distance from each palette entry to its nearest neighbour — the natural dither scale.
    private static func averageNearestDistance(_ p: [PixelRGB]) -> Double {
        guard p.count > 1 else { return 0 }
        var total = 0.0
        for i in 0..<p.count {
            var best = Double.greatestFiniteMagnitude
            for j in 0..<p.count where j != i {
                let dr = Double(Int(p[i].red) - Int(p[j].red))
                let dg = Double(Int(p[i].green) - Int(p[j].green))
                let db = Double(Int(p[i].blue) - Int(p[j].blue))
                best = min(best, (dr * dr + dg * dg + db * db).squareRoot())
            }
            total += best
        }
        return total / Double(p.count)
    }

    private static func clampByte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    /// Classic 8×8 Bayer threshold matrix, normalised to [0, 1).
    private static let bayer8: [[Double]] = {
        let m: [[Int]] = [
            [ 0, 32,  8, 40,  2, 34, 10, 42],
            [48, 16, 56, 24, 50, 18, 58, 26],
            [12, 44,  4, 36, 14, 46,  6, 38],
            [60, 28, 52, 20, 62, 30, 54, 22],
            [ 3, 35, 11, 43,  1, 33,  9, 41],
            [51, 19, 59, 27, 49, 17, 57, 25],
            [15, 47,  7, 39, 13, 45,  5, 37],
            [63, 31, 55, 23, 61, 29, 53, 21],
        ]
        return m.map { $0.map { Double($0) / 64.0 } }
    }()

    // MARK: - Fixed console palettes

    private static func rgb(_ hex: UInt32) -> PixelRGB {
        PixelRGB(red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF))
    }

    /// Original Game Boy DMG — four greens.
    private static let gameBoy = [0x0F380F, 0x306230, 0x8BAC0F, 0x9BBC0F].map { rgb(UInt32($0)) }

    /// PICO-8 fantasy-console 16.
    private static let pico8 = [
        0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
        0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA,
    ].map { rgb(UInt32($0)) }

    /// Commodore 64 16.
    private static let c64 = [
        0x000000, 0xFFFFFF, 0x880000, 0xAAFFEE, 0xCC44CC, 0x00CC55, 0x0000AA, 0xEEEE77,
        0xDD8855, 0x664400, 0xFF7777, 0x333333, 0x777777, 0xAAFF66, 0x0088FF, 0xBBBBBB,
    ].map { rgb(UInt32($0)) }

    /// CGA high-intensity palette 1 — black / cyan / magenta / white.
    private static let cga = [0x000000, 0x55FFFF, 0xFF55FF, 0xFFFFFF].map { rgb(UInt32($0)) }

    /// 1-bit — pure black & white (Game Boy Camera / Mac dither vibe).
    private static let oneBit = [0x000000, 0xFFFFFF].map { rgb(UInt32($0)) }

    /// NES 2C02 master palette (the full usable set; nearest-colour match picks from it).
    private static let nes = [
        0x7C7C7C, 0x0000FC, 0x0000BC, 0x4428BC, 0x940084, 0xA80020, 0xA81000, 0x881400,
        0x503000, 0x007800, 0x006800, 0x005800, 0x004058, 0x000000,
        0xBCBCBC, 0x0078F8, 0x0058F8, 0x6844FC, 0xD800CC, 0xE40058, 0xF83800, 0xE45C10,
        0xAC7C00, 0x00B800, 0x00A800, 0x00A844, 0x008888,
        0xF8F8F8, 0x3CBCFC, 0x6888FC, 0x9878F8, 0xF878F8, 0xF85898, 0xF87858, 0xFCA044,
        0xF8B800, 0xB8F818, 0x58D854, 0x58F898, 0x00E8D8, 0x787878,
        0xFCFCFC, 0xA4E4FC, 0xB8B8F8, 0xD8B8F8, 0xF8B8F8, 0xF8A4C0, 0xF0D0B0, 0xFCE0A8,
        0xF8D878, 0xD8F878, 0xB8F8B8, 0xB8F8D8, 0x00FCFC, 0xF8D8F8,
    ].map { rgb(UInt32($0)) }

    /// ZX Spectrum — 8 base colours at normal + bright intensity (black shared → 15 unique).
    private static let zxSpectrum = [
        0x000000, 0x0000D7, 0xD70000, 0xD700D7, 0x00D700, 0x00D7D7, 0xD7D700, 0xD7D7D7,
        0x0000FF, 0xFF0000, 0xFF00FF, 0x00FF00, 0x00FFFF, 0xFFFF00, 0xFFFFFF,
    ].map { rgb(UInt32($0)) }

    /// Vaporwave — pink / cyan / mint / violet aesthetic.
    private static let vaporwave = [
        0x1A0033, 0x5B2A86, 0xC774E8, 0xFF6AD5, 0x8DDFFF, 0x01CDFE, 0x05FFA1, 0xFFF5F5,
    ].map { rgb(UInt32($0)) }

    // Monochrome / false-colour ramps, ordered dark → light.

    /// Game Boy Pocket — four neutral greys.
    private static let mono = [0x000000, 0x555555, 0xAAAAAA, 0xFFFFFF].map { rgb(UInt32($0)) }

    /// Warm sepia, old-photo.
    private static let sepia = [0x1A1208, 0x4A3420, 0x8A6A42, 0xC8A878, 0xF5E8C8].map { rgb(UInt32($0)) }

    /// Green phosphor terminal.
    private static let greenCRT = [0x001B00, 0x00451A, 0x00873E, 0x33CC55, 0x88FF88].map { rgb(UInt32($0)) }

    /// Amber phosphor terminal.
    private static let amberCRT = [0x180A00, 0x4A2A00, 0x9A6400, 0xE0A000, 0xFFD060, 0xFFF0C0].map { rgb(UInt32($0)) }

    /// Virtual Boy — red on black.
    private static let virtualBoy = [0x000000, 0x550000, 0xAA0000, 0xFF0000].map { rgb(UInt32($0)) }

    /// Thermal / heat-map: black → indigo → magenta → red → orange → yellow → white.
    private static let thermal = [
        0x000008, 0x1A0A4A, 0x6A1B9A, 0xD6336C, 0xFF6B1A, 0xFFD000, 0xFFFFFF,
    ].map { rgb(UInt32($0)) }
}
