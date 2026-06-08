// Design sandbox: renders the 64×64 analog + digital surfaces to upscaled PNGs so the look
// can be iterated WITHOUT the Pixoo. Self-contained (no TimeboxKit). Once a design is final,
// the drawing functions are copied into the real ClockRenderer / DigitalClockRenderer.
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
    init(_ r: Int, _ g: Int, _ b: Int) { red = UInt8(max(0,min(255,r))); green = UInt8(max(0,min(255,g))); blue = UInt8(max(0,min(255,b))) }
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
    func at(_ x: Int, _ y: Int) -> PixelRGB { pixels[y*width + x] }
}

func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v*255).rounded()))) }
func mix(_ a: PixelRGB, _ b: PixelRGB, _ t: Double) -> PixelRGB {
    func l(_ x: UInt8, _ y: UInt8) -> UInt8 { byte((Double(x)*(1-t) + Double(y)*t)/255) }
    return PixelRGB(red: l(a.red,b.red), green: l(a.green,b.green), blue: l(a.blue,b.blue))
}
func darken(_ c: PixelRGB, _ f: Double) -> PixelRGB {
    PixelRGB(red: byte(Double(c.red)/255*f), green: byte(Double(c.green)/255*f), blue: byte(Double(c.blue)/255*f))
}
// Screen-blend `c`·amt over base (bright, neon-like, never darkens).
func screenAdd(_ base: PixelRGB, _ c: PixelRGB, _ amt: Double) -> PixelRGB {
    func ch(_ b: UInt8, _ x: UInt8) -> UInt8 {
        let bb = Double(b)/255, xx = Double(x)/255 * amt
        return byte(1 - (1-bb)*(1-min(1,xx)))
    }
    return PixelRGB(red: ch(base.red,c.red), green: ch(base.green,c.green), blue: ch(base.blue,c.blue))
}
func vivid(_ c: PixelRGB) -> PixelRGB {
    var r = Double(c.red)/255, g = Double(c.green)/255, b = Double(c.blue)/255
    let mx = max(r,g,b), mn = min(r,g,b)
    if mx < 0.04 { return PixelRGB(red: 120, green: 180, blue: 255) }
    let mid = (mx+mn)/2, sat = 1.6
    r = mid + (r-mid)*sat; g = mid + (g-mid)*sat; b = mid + (b-mid)*sat
    let scale = 0.95/mx
    return PixelRGB(red: byte(r*scale), green: byte(g*scale), blue: byte(b*scale))
}
func boxBlur(_ field: [Double], _ w: Int, _ h: Int, _ r: Int) -> [Double] {
    var tmp = [Double](repeating: 0, count: w*h)
    for y in 0..<h { for x in 0..<w {
        var s = 0.0, n = 0
        for dx in -r...r { let xx = x+dx; if xx >= 0 && xx < w { s += field[y*w+xx]; n += 1 } }
        tmp[y*w+x] = s/Double(n)
    }}
    var out = [Double](repeating: 0, count: w*h)
    for y in 0..<h { for x in 0..<w {
        var s = 0.0, n = 0
        for dy in -r...r { let yy = y+dy; if yy >= 0 && yy < h { s += tmp[yy*w+x]; n += 1 } }
        out[y*w+x] = s/Double(n)
    }}
    return out
}

// ---- PixelFont ----
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
                for y in 0..<height { let row = Array(glyph[y]); col[y] = x < row.count && row[x] == "#" }
                cols.append(col)
            }
            for _ in 0..<tracking { cols.append([Bool](repeating: false, count: height)) }
        }
        return cols
    }
}

// =====================================================================================
// ANALOG (final design)
// =====================================================================================
enum AnalogClock {
    static func large(for date: Date, size: Int, accent: PixelRGB?, calendar: Calendar = .current) -> Surface {
        let ss = 8, dim = size*ss
        guard let ctx = CGContext(data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Surface(width: size, height: size) }
        ctx.setShouldAntialias(true); ctx.interpolationQuality = .high; ctx.scaleBy(x: CGFloat(ss), y: CGFloat(ss))
        let cs = CGColorSpaceCreateDeviceRGB(); let s = CGFloat(size); let cx = s/2, cy = s/2; let R = s/2 - 1.5
        let accv = vivid(accent ?? PixelRGB(red: 90, green: 180, blue: 255))
        func cg(_ r: Double,_ g: Double,_ b: Double,_ a: Double=1)->CGColor{CGColor(colorSpace:cs,components:[r,g,b,a])!}
        func cgOf(_ c: PixelRGB,_ a: Double=1)->CGColor{cg(Double(c.red)/255,Double(c.green)/255,Double(c.blue)/255,a)}
        ctx.setFillColor(cg(0,0,0)); ctx.fill(CGRect(x:0,y:0,width:s,height:s))
        func point(_ t: Double,_ r: Double)->CGPoint{let a=t*2 * .pi;return CGPoint(x:cx+r*sin(a),y:cy+r*cos(a))}
        ctx.saveGState(); ctx.addEllipse(in: CGRect(x:cx-R,y:cy-R,width:R*2,height:R*2)); ctx.clip()
        let fg = CGGradient(colorsSpace:cs,colors:[cg(0.09,0.10,0.17),cg(0.04,0.04,0.08),cg(0.01,0.01,0.03)] as CFArray,locations:[0,0.7,1])!
        ctx.drawRadialGradient(fg,startCenter:CGPoint(x:cx,y:cy),startRadius:0,endCenter:CGPoint(x:cx,y:cy),endRadius:R,options:[])
        let bloom = CGGradient(colorsSpace:cs,colors:[cgOf(accv,0.16),cgOf(accv,0)] as CFArray,locations:[0,1])!
        ctx.drawRadialGradient(bloom,startCenter:CGPoint(x:cx,y:cy+R*0.35),startRadius:0,endCenter:CGPoint(x:cx,y:cy+R*0.35),endRadius:R*0.9,options:[])
        ctx.restoreGState()
        ctx.setLineCap(.round)
        ctx.setStrokeColor(cgOf(accv,0.30)); ctx.setLineWidth(1.8); ctx.strokeEllipse(in: CGRect(x:cx-R,y:cy-R,width:R*2,height:R*2))
        ctx.setStrokeColor(cg(0.42,0.50,0.66)); ctx.setLineWidth(0.7); ctx.strokeEllipse(in: CGRect(x:cx-R,y:cy-R,width:R*2,height:R*2))
        ctx.setStrokeColor(cg(0.75,0.82,0.95,0.7)); ctx.setLineWidth(0.3); ctx.strokeEllipse(in: CGRect(x:cx-(R-0.7),y:cy-(R-0.7),width:(R-0.7)*2,height:(R-0.7)*2))
        for i in 0..<60 {
            let t = Double(i)/60.0, isHour = i%5==0, outer = Double(R)-1.6, inner = outer-(isHour ?4.2:1.8)
            let p0 = point(t,outer), p1 = point(t,inner)
            ctx.setLineWidth(isHour ?0.9:0.35); ctx.setStrokeColor(isHour ?cg(0.80,0.86,0.98):cg(0.34,0.39,0.5))
            ctx.move(to:p0); ctx.addLine(to:p1); ctx.strokePath()
        }
        for q in 0..<4 { let p = point(Double(q)/4.0,Double(R)-6.0); ctx.setFillColor(cgOf(accv,0.95)); ctx.fillEllipse(in: CGRect(x:p.x-0.7,y:p.y-0.7,width:1.4,height:1.4)) }
        let c = calendar.dateComponents([.hour,.minute,.second,.nanosecond],from:date)
        let second = Double(c.second ?? 0)+Double(c.nanosecond ?? 0)/1e9
        let minute = Double(c.minute ?? 0)+second/60.0, hour = Double((c.hour ?? 0)%12)+minute/60.0
        func hand(_ turns: Double,_ length: Double,_ baseWidth: Double,_ tail: Double,_ color: PixelRGB,_ glow: PixelRGB,_ gw: Double){
            let t=turns*2 * .pi, dx=sin(t),dy=cos(t),px=cos(t),py = -sin(t)
            let tip=CGPoint(x:cx+length*dx,y:cy+length*dy), back=CGPoint(x:cx-tail*dx,y:cy-tail*dy), h=baseWidth/2
            let bL=CGPoint(x:cx+h*px,y:cy+h*py), bR=CGPoint(x:cx-h*px,y:cy-h*py)
            ctx.setStrokeColor(cgOf(glow,0.35)); ctx.setLineWidth(gw); ctx.setLineCap(.round); ctx.move(to:back); ctx.addLine(to:tip); ctx.strokePath()
            ctx.setFillColor(cgOf(color)); ctx.move(to:back); ctx.addLine(to:bL); ctx.addLine(to:tip); ctx.addLine(to:bR); ctx.closePath(); ctx.fillPath()
        }
        let lightBlue = PixelRGB(red:150,green:195,blue:255), minuteColor = mix(lightBlue,accv,0.5), secColor = PixelRGB(red:255,green:78,blue:60)
        hand(hour/12.0,Double(R)*0.52,3.0,3.2,PixelRGB(red:238,green:242,blue:255),lightBlue,4.5)
        hand(minute/60.0,Double(R)*0.78,2.1,4.0,minuteColor,minuteColor,3.4)
        hand(second/60.0,Double(R)*0.86,0.9,6.0,secColor,secColor,2.2)
        ctx.setFillColor(cg(0.92,0.95,1.0)); ctx.fillEllipse(in: CGRect(x:cx-2.0,y:cy-2.0,width:4.0,height:4.0))
        ctx.setFillColor(cgOf(secColor)); ctx.fillEllipse(in: CGRect(x:cx-0.9,y:cy-0.9,width:1.8,height:1.8))
        guard let img = ctx.makeImage() else { return Surface(width:size,height:size) }
        let bpr=size*4; var buf=[UInt8](repeating:0,count:bpr*size)
        guard let dctx=CGContext(data:&buf,width:size,height:size,bitsPerComponent:8,bytesPerRow:bpr,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return Surface(width:size,height:size) }
        dctx.interpolationQuality = .high; dctx.draw(img,in:CGRect(x:0,y:0,width:size,height:size))
        func lift(_ b: UInt8)->UInt8{ byte(pow(Double(b)/255,0.85)) }
        var px=[PixelRGB](); for y in 0..<size{for x in 0..<size{let o=y*bpr+x*4; px.append(PixelRGB(red:lift(buf[o]),green:lift(buf[o+1]),blue:lift(buf[o+2])))}}
        return Surface(width:size,height:size,pixels:px) ?? Surface(width:size,height:size)
    }
}

// =====================================================================================
// DIGITAL — "hero card": album-art (or synthwave) background + neon-bloom time
// =====================================================================================
enum DigitalClock {
    private enum Token { case digit(Int), colon }
    private static func tokens(_ date: Date,_ cal: Calendar,_ h24: Bool)->[Token]{
        let c=cal.dateComponents([.hour,.minute],from:date); var hour=c.hour ?? 0
        if !h24 { hour%=12; if hour==0 {hour=12} }
        let m=c.minute ?? 0, h1=hour/10,h2=hour%10,m1=m/10,m2=m%10
        var t:[Token]=[]; if h24||h1 != 0 {t.append(.digit(h1))}; t.append(.digit(h2)); t.append(.colon); t.append(.digit(m1)); t.append(.digit(m2)); return t
    }

    static func large(for date: Date, ticker: String, scroll: Int, size: Int, tickerScale: Int,
                      accent: PixelRGB?, art: Surface?, calendar: Calendar = .current, use24Hour: Bool = false) -> Surface {
        var s = Surface(width: size, height: size)
        let acc = vivid(accent ?? PixelRGB(red: 90, green: 180, blue: 255))
        let lit = ((calendar.dateComponents([.second], from: date).second ?? 0) % 2 == 0)
        let titleBand = 16   // bottom rows reserved for the native scrolling title

        // ---- 1. Background ----
        if let art, art.width == size, art.height == size {
            artBackground(into: &s, art: art, accent: acc, titleBand: titleBand)
        } else {
            synthwave(into: &s, accent: acc, titleBand: titleBand)
        }

        // ---- 2. Lay out the time ----
        let scale = 3
        let glyphH = PixelFont.height * scale
        let toks = tokens(date, calendar, use24Hour)
        let gap = scale
        let cols = toks.map { t -> [[Bool]] in
            switch t { case .digit(let d): return PixelFont.columns(for: String(d), tracking: 0)
                       case .colon: return PixelFont.columns(for: ":", tracking: 0) }
        }
        let totalW = cols.map { $0.count*scale }.reduce(0,+) + gap*(toks.count-1)
        let originX = (size - totalW)/2
        let topY = (size - titleBand - glyphH)/2 - 1    // centered in the area above the title band

        // mask of lit time pixels (for the neon bloom)
        var mask = [Double](repeating: 0, count: size*size)
        var x = originX
        for (i, cc) in cols.enumerated() {
            let isColon: Bool = { if case .colon = toks[i] { return true }; return false }()
            if !(isColon && !lit) {
                for (gx, col) in cc.enumerated() { for (gy, on) in col.enumerated() where on {
                    let px = x + gx*scale, py = topY + gy*scale
                    for dy in 0..<scale { for dx in 0..<scale {
                        let xx = px+dx, yy = py+dy
                        if xx>=0 && yy>=0 && xx<size && yy<size { mask[yy*size+xx] = 1 }
                    }}
                }}
            }
            x += cc.count*scale + (i < toks.count-1 ? gap : 0)
        }

        // ---- 3. Dark scrim behind the time (legibility over art), then neon bloom ----
        let glow = boxBlur(boxBlur(mask, size, size, 3), size, size, 2)
        for i in 0..<s.pixels.count {
            let g = glow[i]
            if g > 0.002 {
                // dip the background where the glow is, so the neon reads against busy art
                s.pixels[i] = darken(s.pixels[i], 1 - min(0.55, g*1.4))
                s.pixels[i] = screenAdd(s.pixels[i], acc, min(1.0, g*2.4))
            }
        }

        // ---- 4. Draw the digits: black tube edge + bright gradient core ----
        let gradTop = PixelRGB(red: 255, green: 255, blue: 255)
        let gradBottom = mix(acc, PixelRGB(red: 255, green: 255, blue: 255), 0.35)
        // edge first (1px black around lit pixels)
        for y in 0..<size { for xx in 0..<size where mask[y*size+xx] == 0 {
            var near = false
            outer: for dy in -1...1 { for dx in -1...1 {
                let nx=xx+dx, ny=y+dy
                if nx>=0 && ny>=0 && nx<size && ny<size && mask[ny*size+nx] == 1 { near = true; break outer }
            }}
            if near { s.set(xx, y, mix(s.at(xx,y), PixelRGB(red:0,green:0,blue:0), 0.6)) }
        }}
        for y in 0..<size { for xx in 0..<size where mask[y*size+xx] == 1 {
            let t = Double(y - topY) / Double(max(1, glyphH-1))
            s.set(xx, y, mix(gradTop, gradBottom, max(0, min(1, t))))
        }}

        // ---- 5. Preview-only illustrative scrolling ticker in the title band ----
        let text = ticker.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let th = PixelFont.height * tickerScale
            let ty = size - th - 3
            for (i, col) in PixelFont.columns(for: text).enumerated() {
                let sx = i*tickerScale - scroll + size
                if sx <= -tickerScale || sx >= size { continue }
                for gy in 0..<PixelFont.height where col[gy] {
                    for dx in 0..<tickerScale { for dy in 0..<tickerScale {
                        s.set(sx+dx, ty+gy*tickerScale+dy, PixelRGB(red:240,green:245,blue:255))
                    }}
                }
            }
        }
        return s
    }

    // Album art, darkened + vignetted, with a strong scrim under the title band.
    private static func artBackground(into s: inout Surface, art: Surface, accent: PixelRGB, titleBand: Int) {
        let size = s.width
        let cx = Double(size)/2, cy = Double(size)/2, maxd = (Double(size)/2)*1.18
        for y in 0..<size { for x in 0..<size {
            var c = darken(art.at(x,y), 0.42)
            // radial vignette
            let d = (((Double(x)-cx)*(Double(x)-cx) + (Double(y)-cy)*(Double(y)-cy)).squareRoot()) / maxd
            c = darken(c, 1 - min(0.6, d*0.6))
            // title band scrim (fade in toward the bottom)
            let intoBand = y - (size - titleBand)
            if intoBand > -2 {
                let f = min(1.0, Double(intoBand + 2) / Double(titleBand))
                c = darken(c, 1 - 0.72*f)
            }
            s.set(x, y, c)
        }}
        // a faint accent rule above the title band
        let ry = size - titleBand - 1
        for x in 4..<(size-4) {
            let edge = min(x-4, (size-5)-x)
            s.set(x, ry, mix(s.at(x,ry), accent, 0.5 * min(1.0, Double(edge)/6.0)))
        }
    }

    // Retro "synthwave" fallback: gradient sky, a slit sun, and a perspective grid.
    private static func synthwave(into s: inout Surface, accent: PixelRGB, titleBand: Int) {
        let size = s.width
        let horizon = Int(Double(size) * 0.60)
        let skyTop = PixelRGB(red: 14, green: 6, blue: 34)
        let skyHorizon = mix(PixelRGB(red: 90, green: 20, blue: 90), accent, 0.35)
        // sky
        for y in 0..<horizon { for x in 0..<size {
            s.set(x, y, mix(skyTop, skyHorizon, pow(Double(y)/Double(horizon), 1.6)))
        }}
        // sun: vertical gradient disc with horizontal slits in the lower half
        let sunR = Double(size) * 0.26
        let sx = Double(size)/2, sy = Double(horizon) - sunR*0.35
        let sunTop = PixelRGB(red: 255, green: 240, blue: 180)
        let sunBot = vivid(mix(accent, PixelRGB(red: 255, green: 60, blue: 140), 0.5))
        for y in 0..<horizon { for x in 0..<size {
            let dx = Double(x)-sx, dy = Double(y)-sy
            if dx*dx + dy*dy <= sunR*sunR {
                let t = (Double(y) - (sy - sunR)) / (2*sunR)
                var c = mix(sunTop, sunBot, max(0, min(1, t)))
                // slits: thicker/closer toward the bottom of the sun
                let below = Double(y) - sy
                if below > 0 {
                    let period = 2.0 + (1 - below/sunR) * 5.0
                    if Int(below).quotientAndRemainder(dividingBy: max(2, Int(period))).remainder == 0 { c = darken(c, 0.15) }
                }
                s.set(x, y, c)
            }
        }}
        // ground
        for y in horizon..<size { for x in 0..<size {
            s.set(x, y, mix(PixelRGB(red: 18, green: 6, blue: 30), PixelRGB(red: 4, green: 2, blue: 10), Double(y-horizon)/Double(size-horizon)))
        }}
        let gridColor = vivid(accent)
        // horizontal grid lines (denser toward the bottom)
        var i = 0
        while true {
            let frac = pow(Double(i)/10.0, 1.8)
            let y = horizon + Int(frac * Double(size - horizon))
            if y >= size { break }
            for x in 0..<size { s.set(x, y, mix(s.at(x,y), gridColor, 0.55)) }
            i += 1
        }
        // vertical grid lines converging to the vanishing point
        let vpx = Double(size)/2
        for k in -7...7 {
            for y in horizon..<size {
                let p = Double(y - horizon) / Double(size - horizon)
                let xx = Int(vpx + Double(k) * p * (Double(size) * 0.16))
                if xx >= 0 && xx < size { s.set(xx, y, mix(s.at(xx,y), gridColor, 0.35)) }
            }
        }
        // title band scrim
        for y in (size - titleBand)..<size { for x in 0..<size {
            let f = Double(y - (size - titleBand) + 1) / Double(titleBand)
            s.set(x, y, darken(s.at(x,y), 1 - 0.7*f))
        }}
    }
}

// ---- fake album art for preview ----
func fakeArt(_ size: Int, _ style: Int) -> Surface {
    var s = Surface(width: size, height: size)
    for y in 0..<size { for x in 0..<size {
        let u = Double(x)/Double(size), v = Double(y)/Double(size)
        var c: PixelRGB
        switch style {
        case 0: // warm sunset
            c = mix(PixelRGB(red: 250, green: 180, blue: 60), PixelRGB(red: 200, green: 30, blue: 90), v)
            c = mix(c, PixelRGB(red: 40, green: 10, blue: 70), pow(v, 2))
        default: // teal/purple diagonal
            c = mix(PixelRGB(red: 0, green: 190, blue: 200), PixelRGB(red: 120, green: 30, blue: 200), (u+v)/2)
        }
        s.set(x, y, c)
    }}
    // a couple of "shapes" so it's not a flat gradient
    let cxs = [Double(size)*0.30, Double(size)*0.72], cys = [Double(size)*0.35, Double(size)*0.66]
    let cols = [PixelRGB(red: 255, green: 240, blue: 200), PixelRGB(red: 30, green: 200, blue: 255)]
    for j in 0..<2 { for y in 0..<size { for x in 0..<size {
        let dx = Double(x)-cxs[j], dy = Double(y)-cys[j], r = Double(size)*0.16
        if dx*dx+dy*dy < r*r { s.set(x, y, mix(s.at(x,y), cols[j], 0.5)) }
    }}}
    return s
}

// ---- PNG export ----
func writePNG(_ surface: Surface, scale: Int, to path: String) {
    let w = surface.width*scale, h = surface.height*scale
    var buf = [UInt8](repeating: 0, count: w*h*4)
    for y in 0..<h { for x in 0..<w {
        let sp = surface.pixels[(y/scale)*surface.width + (x/scale)]; let o = (y*w+x)*4
        buf[o]=sp.red; buf[o+1]=sp.green; buf[o+2]=sp.blue; buf[o+3]=255
    }}
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data:&buf,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
}

// ---- main ----
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/preview"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let cal = Calendar(identifier: .gregorian)
func date(_ h: Int,_ m: Int,_ s: Int)->Date{ var c=DateComponents(); c.year=2026;c.month=6;c.day=7;c.hour=h;c.minute=m;c.second=s; return cal.date(from:c)! }
let scale = 8
let teal = PixelRGB(red: 0, green: 200, blue: 180), gold = PixelRGB(red: 255, green: 180, blue: 40)

writePNG(AnalogClock.large(for: date(10,9,36), size: 64, accent: nil), scale: scale, to: "\(outDir)/analog_default.png")

writePNG(DigitalClock.large(for: date(10,9,0), ticker: "DAFT PUNK — GET LUCKY", scroll: 22, size: 64, tickerScale: 2, accent: nil, art: nil), scale: scale, to: "\(outDir)/digital_synthwave.png")
writePNG(DigitalClock.large(for: date(1,51,0), ticker: "ODESZA — SUN MODELS", scroll: 14, size: 64, tickerScale: 2, accent: teal, art: nil), scale: scale, to: "\(outDir)/digital_synthwave2.png")
let artA = fakeArt(64, 0), artB = fakeArt(64, 1)
let accA = vivid(PixelRGB(red: 240, green: 90, blue: 70)), accB = vivid(PixelRGB(red: 40, green: 200, blue: 220))
writePNG(DigitalClock.large(for: date(10,9,0), ticker: "TAME IMPALA — LET IT HAPPEN", scroll: 20, size: 64, tickerScale: 2, accent: accA, art: artA), scale: scale, to: "\(outDir)/digital_art_warm.png")
writePNG(DigitalClock.large(for: date(12,34,0), ticker: "BONOBO — KERALA", scroll: 16, size: 64, tickerScale: 2, accent: accB, art: artB), scale: scale, to: "\(outDir)/digital_art_cool.png")
writePNG(fakeArt(64, 0), scale: scale, to: "\(outDir)/_art_warm_src.png")
print("wrote previews to \(outDir)")
