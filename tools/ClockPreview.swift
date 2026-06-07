// Design sandbox: renders the new 64×64 analog + digital surfaces to upscaled PNGs so the
// look can be iterated WITHOUT the Pixoo. Self-contained (no TimeboxKit). Once a design is
// final, the drawing functions here are copied into the real ClockRenderer /
// DigitalClockRenderer `large(...)` paths (which import PixelRGB from TimeboxKit instead of
// defining it locally). Compile + run on macOS:
//
//   swiftc -O tools/ClockPreview.swift -o /tmp/clockpreview && /tmp/clockpreview /tmp/preview
//
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PixelRGB: Equatable {
    var red: UInt8, green: UInt8, blue: UInt8
    init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }
}

struct Surface {
    let width: Int, height: Int
    var pixels: [PixelRGB]
    init(width: Int, height: Int, fill: PixelRGB = PixelRGB(red: 0, green: 0, blue: 0)) {
        self.width = width; self.height = height
        self.pixels = Array(repeating: fill, count: width * height)
    }
    init?(width: Int, height: Int, pixels: [PixelRGB]) {
        guard pixels.count == width * height else { return nil }
        self.width = width; self.height = height; self.pixels = pixels
    }
    mutating func set(_ x: Int, _ y: Int, _ c: PixelRGB) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        pixels[y * width + x] = c
    }
}

// ---- PixelFont (copied verbatim from the app) ----
enum PixelFont {
    static let height = 5
    private static let glyphs: [Character: [String]] = [
        " ": [".",".",".",".","."],
        "A": [".##.","#..#","####","#..#","#..#"], "B": ["###.","#..#","###.","#..#","###."],
        "C": [".##.","#..#","#...","#..#",".##."], "D": ["###.","#..#","#..#","#..#","###."],
        "E": ["###","#..","###","#..","###"], "F": ["###","#..","##.","#..","#.."],
        "G": [".##.","#...","#.##","#..#",".##."], "H": ["#..#","#..#","####","#..#","#..#"],
        "I": ["#","#","#","#","#"], "J": ["...#","...#","...#","#..#",".##."],
        "K": ["#..#","#.#.","##..","#.#.","#..#"], "L": ["#..","#..","#..","#..","###"],
        "M": ["#...#","##.##","#.#.#","#...#","#...#"], "N": ["#..#","##.#","#.##","#..#","#..#"],
        "O": [".##.","#..#","#..#","#..#",".##."], "P": ["###.","#..#","###.","#...","#..."],
        "Q": [".##.","#..#","#..#","#.##",".###"], "R": ["###.","#..#","###.","#..#","#..#"],
        "S": [".###","#...",".##.","...#","###."], "T": ["###",".#.",".#.",".#.",".#."],
        "U": ["#..#","#..#","#..#","#..#",".##."], "V": ["#...#","#...#",".#.#.",".#.#.","..#.."],
        "W": ["#...#","#...#","#.#.#","#.#.#",".#.#."], "X": ["#..#","#..#",".##.","#..#","#..#"],
        "Y": ["#..#","#..#",".###","...#","###."], "Z": ["####","...#",".##.","#...","####"],
        "1": [".#","##",".#",".#",".#"], "2": [".##.","#..#","..#.",".#..","####"],
        "3": [".##.","#..#","..#.","#..#",".##."], "4": ["#..#","#..#","####","...#","...#"],
        "5": ["###.","#...","###.","...#","###."], "6": [".##.","#...","###.","#..#",".##."],
        "7": ["####","...#","..#.","..#.",".#.."], "8": [".##.","#..#",".##.","#..#",".##."],
        "9": [".##.","#..#",".###","...#",".##."], "0": [".##.","##.#","#..#","#.##",".##."],
        "+": ["..#..","..#..","#####","..#..","..#.."], "-": ["....","....","####","....","...."],
        "(": [".#","#.","#.","#.",".#"], ")": ["#.",".#",".#",".#","#."],
        "*": [".#.#.","..#..","#####","..#..",".#.#."], "/": ["..#","..#",".#.","#..","#.."],
        "#": [".#.#.","#####",".#.#.","#####",".#.#."], "@": [".###.","#.#.#","#.###","#....",".###."],
        ".": [".",".",".",".","#"], ":": [".","#",".","#","."],
        ",": ["..","..","..",".#","#."], "\"": ["#.#","#.#","...","...","..."],
        "'": [".#",".#","#.","..",".."], "&": [".##..","#....",".#..#","#..#.",".##.#"]
    ]
    static func columns(for text: String, tracking: Int = 1) -> [[Bool]] {
        var cols: [[Bool]] = []
        for raw in text {
            let ch: Character = (raw == "\u{2014}" || raw == "\u{2013}") ? "-" : raw
            let glyph = glyphs[ch] ?? ch.uppercased().first.flatMap { glyphs[$0] } ?? glyphs[" "]!
            let width = glyph.map { $0.count }.max() ?? 0
            for x in 0..<width {
                var col = [Bool](repeating: false, count: height)
                for y in 0..<height {
                    let row = Array(glyph[y]); col[y] = x < row.count && row[x] == "#"
                }
                cols.append(col)
            }
            for _ in 0..<tracking { cols.append([Bool](repeating: false, count: height)) }
        }
        return cols
    }
}

// =====================================================================================
// ANALOG — beautiful 64×64
// =====================================================================================
enum AnalogClock {
    static func large(for date: Date, size: Int, accent: PixelRGB?, calendar: Calendar = .current) -> Surface {
        let ss = 8
        let dim = size * ss
        guard let ctx = CGContext(data: nil, width: dim, height: dim, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Surface(width: size, height: size)
        }
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(ss), y: CGFloat(ss))   // work in 0…size coordinates

        let cs = CGColorSpaceCreateDeviceRGB()
        let s = CGFloat(size)
        let cx = s / 2, cy = s / 2
        let R = s / 2 - 1.5                            // face radius

        let acc = accent ?? PixelRGB(red: 90, green: 180, blue: 255)
        let accv = vivid(acc)
        func cg(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
            CGColor(colorSpace: cs, components: [r, g, b, a])!
        }
        func cgOf(_ c: PixelRGB, _ a: Double = 1) -> CGColor {
            cg(Double(c.red)/255, Double(c.green)/255, Double(c.blue)/255, a)
        }

        // Background.
        ctx.setFillColor(cg(0, 0, 0)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        func point(_ turns: Double, _ radius: Double) -> CGPoint {
            let t = turns * 2 * .pi
            return CGPoint(x: cx + radius * sin(t), y: cy + radius * cos(t))
        }

        // Face: radial gradient disc (deep indigo center → near-black rim) + faint accent bloom.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: cx - R, y: cy - R, width: R*2, height: R*2)); ctx.clip()
        let faceGrad = CGGradient(colorsSpace: cs, colors: [
            cg(0.09, 0.10, 0.17), cg(0.04, 0.04, 0.08), cg(0.01, 0.01, 0.03)
        ] as CFArray, locations: [0, 0.7, 1])!
        ctx.drawRadialGradient(faceGrad, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy), endRadius: R, options: [])
        // Accent bloom toward the top, very subtle.
        let bloom = CGGradient(colorsSpace: cs, colors: [cgOf(accv, 0.16), cgOf(accv, 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: cx, y: cy + R*0.35), startRadius: 0,
                               endCenter: CGPoint(x: cx, y: cy + R*0.35), endRadius: R*0.9, options: [])
        ctx.restoreGState()

        // Bezel: soft outer glow ring + crisp rim + inner highlight.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(cgOf(accv, 0.30)); ctx.setLineWidth(1.8)
        ctx.strokeEllipse(in: CGRect(x: cx - R, y: cy - R, width: R*2, height: R*2))
        ctx.setStrokeColor(cg(0.42, 0.50, 0.66)); ctx.setLineWidth(0.7)
        ctx.strokeEllipse(in: CGRect(x: cx - R, y: cy - R, width: R*2, height: R*2))
        ctx.setStrokeColor(cg(0.75, 0.82, 0.95, 0.7)); ctx.setLineWidth(0.3)
        ctx.strokeEllipse(in: CGRect(x: cx - (R-0.7), y: cy - (R-0.7), width: (R-0.7)*2, height: (R-0.7)*2))

        // Ticks: 60 fine minute ticks, brighter & longer at the 12 hours.
        for i in 0..<60 {
            let turns = Double(i) / 60.0
            let isHour = i % 5 == 0
            let outer = Double(R) - 1.6
            let inner = outer - (isHour ? 4.2 : 1.8)
            let p0 = point(turns, outer), p1 = point(turns, inner)
            ctx.setLineWidth(isHour ? 0.9 : 0.35)
            ctx.setStrokeColor(isHour ? cg(0.80, 0.86, 0.98) : cg(0.34, 0.39, 0.5))
            ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
        }
        // Quarter accents: small bright dots at 12/3/6/9.
        for q in 0..<4 {
            let p = point(Double(q) / 4.0, Double(R) - 6.0)
            ctx.setFillColor(cgOf(accv, 0.95))
            ctx.fillEllipse(in: CGRect(x: p.x - 0.7, y: p.y - 0.7, width: 1.4, height: 1.4))
        }

        let comps = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let second = Double(comps.second ?? 0) + Double(comps.nanosecond ?? 0) / 1e9
        let minute = Double(comps.minute ?? 0) + second / 60.0
        let hour = Double((comps.hour ?? 0) % 12) + minute / 60.0

        // Tapered hand (kite polygon) with an optional soft glow underneath.
        func hand(turns: Double, length: Double, baseWidth: Double, tail: Double,
                  color: PixelRGB, glow: PixelRGB?, glowWidth: Double) {
            let t = turns * 2 * .pi
            let dx = sin(t), dy = cos(t)            // tip direction
            let px = cos(t), py = -sin(t)           // perpendicular
            let tip = CGPoint(x: cx + length*dx, y: cy + length*dy)
            let back = CGPoint(x: cx - tail*dx, y: cy - tail*dy)
            let h = baseWidth/2
            let bL = CGPoint(x: cx + h*px, y: cy + h*py)
            let bR = CGPoint(x: cx - h*px, y: cy - h*py)
            if let glow {
                ctx.setStrokeColor(cgOf(glow, 0.35)); ctx.setLineWidth(glowWidth); ctx.setLineCap(.round)
                ctx.move(to: back); ctx.addLine(to: tip); ctx.strokePath()
            }
            ctx.setFillColor(cgOf(color))
            ctx.move(to: back); ctx.addLine(to: bL); ctx.addLine(to: tip); ctx.addLine(to: bR)
            ctx.closePath(); ctx.fillPath()
        }

        let lightBlue = PixelRGB(red: 150, green: 195, blue: 255)
        let minuteColor = mix(lightBlue, accv, 0.5)        // leans to the theme, stays bright
        hand(turns: hour/12.0, length: Double(R)*0.52, baseWidth: 3.0, tail: 3.2,
             color: PixelRGB(red: 238, green: 242, blue: 255), glow: lightBlue, glowWidth: 4.5)
        hand(turns: minute/60.0, length: Double(R)*0.78, baseWidth: 2.1, tail: 4.0,
             color: minuteColor, glow: minuteColor, glowWidth: 3.4)
        // Second hand: a fixed warm red so it always pops, even against a cool accent theme.
        let secColor = PixelRGB(red: 255, green: 78, blue: 60)
        hand(turns: second/60.0, length: Double(R)*0.86, baseWidth: 0.9, tail: 6.0,
             color: secColor, glow: secColor, glowWidth: 2.2)

        // Center hub.
        ctx.setFillColor(cg(0.92, 0.95, 1.0))
        ctx.fillEllipse(in: CGRect(x: cx - 2.0, y: cy - 2.0, width: 4.0, height: 4.0))
        ctx.setFillColor(cgOf(secColor))
        ctx.fillEllipse(in: CGRect(x: cx - 0.9, y: cy - 0.9, width: 1.8, height: 1.8))

        guard let img = ctx.makeImage() else { return Surface(width: size, height: size) }
        return downsample(img, to: size)
    }

    private static func downsample(_ image: CGImage, to size: Int) -> Surface {
        let bpr = size * 4
        var buf = [UInt8](repeating: 0, count: bpr * size)
        guard let ctx = CGContext(data: &buf, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Surface(width: size, height: size)
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        var px = [PixelRGB](); px.reserveCapacity(size*size)
        for y in 0..<size { for x in 0..<size {
            let o = y*bpr + x*4
            // Gentle LED lift so dim AA pixels still register, without crushing gradients.
            func lift(_ b: UInt8) -> UInt8 {
                let v = pow(Double(b)/255, 0.85); return UInt8(max(0, min(255, (v*255).rounded())))
            }
            px.append(PixelRGB(red: lift(buf[o]), green: lift(buf[o+1]), blue: lift(buf[o+2])))
        }}
        return Surface(width: size, height: size, pixels: px) ?? Surface(width: size, height: size)
    }
}

// Push a color to a vivid, bright version (for accents/glows).
func vivid(_ c: PixelRGB) -> PixelRGB {
    var r = Double(c.red)/255, g = Double(c.green)/255, b = Double(c.blue)/255
    let mx = max(r,g,b), mn = min(r,g,b)
    if mx < 0.04 { return PixelRGB(red: 120, green: 180, blue: 255) }   // near-black → default
    // Boost saturation and lift value.
    let mid = (mx+mn)/2
    let sat = 1.6
    r = mid + (r-mid)*sat; g = mid + (g-mid)*sat; b = mid + (b-mid)*sat
    let scale = mx > 0 ? min(1.0, 0.95)/mx : 1
    r *= scale*1.0; g *= scale*1.0; b *= scale*1.0
    func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v*255).rounded()))) }
    return PixelRGB(red: byte(r), green: byte(g), blue: byte(b))
}

// =====================================================================================
// DIGITAL — exciting 64×64
// =====================================================================================
enum DigitalClock {
    private enum Token { case digit(Int), colon }
    private static func timeTokens(_ date: Date, _ cal: Calendar, _ h24: Bool) -> [Token] {
        let c = cal.dateComponents([.hour, .minute], from: date)
        var hour = c.hour ?? 0
        if !h24 { hour %= 12; if hour == 0 { hour = 12 } }
        let m = c.minute ?? 0
        let h1 = hour/10, h2 = hour%10, m1 = m/10, m2 = m%10
        var t: [Token] = []
        if h24 || h1 != 0 { t.append(.digit(h1)) }
        t.append(.digit(h2)); t.append(.colon); t.append(.digit(m1)); t.append(.digit(m2))
        return t
    }

    static func large(for date: Date, ticker: String, scroll: Int, size: Int, tickerScale: Int,
                      accent: PixelRGB?, calendar: Calendar = .current, use24Hour: Bool = false) -> Surface {
        var surface = Surface(width: size, height: size)
        let acc = vivid(accent ?? PixelRGB(red: 90, green: 180, blue: 255))
        let lit = ((calendar.dateComponents([.second], from: date).second ?? 0) % 2 == 0)

        let timeScale = 3
        let glyphH = PixelFont.height * timeScale            // 15
        let tokens = timeTokens(date, calendar, use24Hour)
        let gap = timeScale

        let tokenCols = tokens.map { tok -> [[Bool]] in
            switch tok {
            case .digit(let d): return PixelFont.columns(for: String(d), tracking: 0)
            case .colon: return PixelFont.columns(for: ":", tracking: 0)
            }
        }
        let totalW = tokenCols.map { $0.count * timeScale }.reduce(0, +) + gap * (tokens.count - 1)
        let originX = (size - totalW) / 2
        let topY = max(0, (size / 2 - glyphH) / 2)        // centered in the top half

        // Soft accent glow behind the time.
        radialGlow(into: &surface, cx: size/2, cy: topY + glyphH/2, radius: 26,
                   color: acc, peak: 0.26)

        // Gradient digit fill (top light → accent toward the bottom) with a neon halo.
        let top = PixelRGB(red: 255, green: 255, blue: 255)
        let bottom = mix(acc, PixelRGB(red: 255, green: 255, blue: 255), 0.25)
        var x = originX
        for (i, cols) in tokenCols.enumerated() {
            let isColon: Bool = { if case .colon = tokens[i] { return true }; return false }()
            if !(isColon && !lit) {
                let color = isColon ? acc : nil   // colon flat accent; digits gradient
                blitGlow(cols, originX: x, originY: topY, scale: timeScale, halo: acc, into: &surface)
                blit(cols, originX: x, originY: topY, scale: timeScale,
                     gradTop: top, gradBottom: bottom, flat: color, glyphH: glyphH, into: &surface)
            }
            x += cols.count * timeScale + (i < tokens.count - 1 ? gap : 0)
        }

        // Accent underline directly beneath the time (edge-faded). Kept clear of the bottom
        // band where the Pixoo's native text engine scrolls the title.
        let black = PixelRGB(red: 0, green: 0, blue: 0)
        let ulY = topY + glyphH + 2
        let ulHalf = totalW/2 + 2
        for bx in (size/2 - ulHalf)...(size/2 + ulHalf) {
            let edge = min(bx - (size/2 - ulHalf), (size/2 + ulHalf) - bx)
            let a = min(1.0, Double(edge) / 5.0)
            surface.set(bx, ulY, mix(black, acc, 0.9 * a))
        }

        // (In the app the scrolling title is drawn by the Pixoo's native text engine at the
        // bottom band; here we draw a streamed-style ticker so the preview shows the layout.)
        let tickerH = PixelFont.height * tickerScale
        let text = ticker.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let tickerTopY = size - tickerH - 3
            for (i, col) in PixelFont.columns(for: text).enumerated() {
                let screenX = i * tickerScale - scroll + size
                if screenX <= -tickerScale || screenX >= size { continue }
                for y in 0..<PixelFont.height where col[y] {
                    for dx in 0..<tickerScale { for dy in 0..<tickerScale {
                        surface.set(screenX + dx, tickerTopY + y*tickerScale + dy, acc)
                    }}
                }
            }
        }
        return surface
    }

    private static func blit(_ columns: [[Bool]], originX: Int, originY: Int, scale: Int,
                             gradTop: PixelRGB, gradBottom: PixelRGB, flat: PixelRGB?,
                             glyphH: Int, into surface: inout Surface) {
        for (cx, col) in columns.enumerated() {
            for (cy, on) in col.enumerated() where on {
                let px = originX + cx*scale, py = originY + cy*scale
                let t = Double(cy*scale) / Double(max(1, glyphH - 1))
                let color = flat ?? mix(gradTop, gradBottom, t)
                for dy in 0..<scale { for dx in 0..<scale { surface.set(px+dx, py+dy, color) } }
            }
        }
    }

    // 1px neon halo around the glyph (only onto currently-dark pixels).
    private static func blitGlow(_ columns: [[Bool]], originX: Int, originY: Int, scale: Int,
                                 halo: PixelRGB, into surface: inout Surface) {
        let h = mix(PixelRGB(red: 0,green: 0,blue: 0), halo, 0.55)
        for (cx, col) in columns.enumerated() {
            for (cy, on) in col.enumerated() where on {
                let px = originX + cx*scale, py = originY + cy*scale
                for dy in -1...scale { for dx in -1...scale {
                    let xx = px+dx, yy = py+dy
                    if xx < 0 || yy < 0 || xx >= surface.width || yy >= surface.height { continue }
                    if surface.pixels[yy*surface.width + xx] == PixelRGB(red:0,green:0,blue:0) {
                        surface.set(xx, yy, h)
                    }
                }}
            }
        }
    }

    private static func radialGlow(into surface: inout Surface, cx: Int, cy: Int, radius: Int,
                                   color: PixelRGB, peak: Double) {
        for y in 0..<surface.height { for x in 0..<surface.width {
            let d = sqrt(Double((x-cx)*(x-cx) + (y-cy)*(y-cy)))
            if d > Double(radius) { continue }
            let a = peak * (1 - d/Double(radius))
            let base = surface.pixels[y*surface.width + x]
            surface.set(x, y, mix(base, color, a))
        }}
    }
}

func mix(_ a: PixelRGB, _ b: PixelRGB, _ t: Double) -> PixelRGB {
    func l(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(x)*(1-t) + Double(y)*t).rounded()))) }
    return PixelRGB(red: l(a.red,b.red), green: l(a.green,b.green), blue: l(a.blue,b.blue))
}

// ---- PNG export (nearest-neighbor upscale so real pixels are visible) ----
func writePNG(_ surface: Surface, scale: Int, to path: String) {
    let w = surface.width * scale, h = surface.height * scale
    var buf = [UInt8](repeating: 0, count: w*h*4)
    for y in 0..<h { for x in 0..<w {
        let sp = surface.pixels[(y/scale)*surface.width + (x/scale)]
        let o = (y*w + x)*4
        buf[o] = sp.red; buf[o+1] = sp.green; buf[o+2] = sp.blue; buf[o+3] = 255
    }}
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// ---- main ----
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/preview"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var cal = Calendar(identifier: .gregorian)
func date(_ h: Int, _ m: Int, _ s: Int) -> Date {
    var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 7; c.hour = h; c.minute = m; c.second = s
    return cal.date(from: c)!
}
let scale = 8
let teal = PixelRGB(red: 0, green: 200, blue: 180)
let magenta = PixelRGB(red: 235, green: 50, blue: 170)
let gold = PixelRGB(red: 255, green: 180, blue: 40)

writePNG(AnalogClock.large(for: date(10, 9, 36), size: 64, accent: nil), scale: scale, to: "\(outDir)/analog_default.png")
writePNG(AnalogClock.large(for: date(1, 51, 8), size: 64, accent: teal), scale: scale, to: "\(outDir)/analog_teal.png")
writePNG(AnalogClock.large(for: date(7, 22, 50), size: 64, accent: magenta), scale: scale, to: "\(outDir)/analog_magenta.png")

writePNG(DigitalClock.large(for: date(10, 9, 0), ticker: "DAFT PUNK — GET LUCKY", scroll: 24, size: 64, tickerScale: 2, accent: nil), scale: scale, to: "\(outDir)/digital_default.png")
writePNG(DigitalClock.large(for: date(1, 51, 0), ticker: "TAME IMPALA — THE LESS I KNOW", scroll: 30, size: 64, tickerScale: 2, accent: teal), scale: scale, to: "\(outDir)/digital_teal.png")
writePNG(DigitalClock.large(for: date(12, 34, 0), ticker: "ODESZA — SUN MODELS", scroll: 18, size: 64, tickerScale: 2, accent: gold), scale: scale, to: "\(outDir)/digital_gold.png")

print("wrote previews to \(outDir)")
