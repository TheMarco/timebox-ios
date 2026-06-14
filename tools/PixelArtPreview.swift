// Pixel-art treatment sandbox → PNGs. Mirrors Sources/Rendering/{ImageToSurface,ImageEnhance,
// PixelArt}.swift so the look can be judged outside the app.
//   swiftc -O tools/PixelArtPreview.swift -o /tmp/papreview && /tmp/papreview <image> /tmp/preview
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PixelRGB: Equatable { var red: UInt8, green: UInt8, blue: UInt8 }
struct Surface { let width: Int, height: Int; var pixels: [PixelRGB] }

// ---- load + downscale (mirrors ImageToSurface, .high interpolation) ----
func loadSurface(_ path: String, size: Int) -> Surface? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let bpr = size * 4
    var buf = [UInt8](repeating: 0, count: bpr * size)
    guard let ctx = CGContext(data: &buf, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    var px = [PixelRGB]()
    for y in 0..<size { for x in 0..<size { let o = y*bpr + x*4
        px.append(PixelRGB(red: buf[o], green: buf[o+1], blue: buf[o+2])) } }
    return Surface(width: size, height: size, pixels: px)
}

// ---- punchUp (mirrors ImageEnhance) ----
func punchUp(_ s: Surface, saturation: Double = 1.5, contrast: Double = 1.18) -> Surface {
    func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v*255).rounded()))) }
    let px = s.pixels.map { p -> PixelRGB in
        var r = Double(p.red)/255, g = Double(p.green)/255, b = Double(p.blue)/255
        func con(_ v: Double) -> Double { (v-0.5)*contrast + 0.5 }
        r = con(r); g = con(g); b = con(b)
        let l = 0.299*r + 0.587*g + 0.114*b
        r = l + (r-l)*saturation; g = l + (g-l)*saturation; b = l + (b-l)*saturation
        return PixelRGB(red: byte(r), green: byte(g), blue: byte(b))
    }
    return Surface(width: s.width, height: s.height, pixels: px)
}

// ---- PixelArt (verbatim catalogue + algorithm from Sources/Rendering/PixelArt.swift) ----
enum PixelArt {
    struct Style { let id: String; let palette: PaletteSource; let dither: Double }
    enum PaletteSource { case adaptive(colors: Int); case fixed([PixelRGB]); case ramp([PixelRGB]) }
    static let presets: [Style] = [
        Style(id: "Soft",       palette: .adaptive(colors: 24), dither: 0.35),
        Style(id: "Classic",    palette: .adaptive(colors: 16), dither: 0.50),
        Style(id: "Crunchy",    palette: .adaptive(colors: 8),  dither: 0.90),
        Style(id: "Game Boy",   palette: .fixed(gameBoy),       dither: 0.80),
        Style(id: "PICO-8",     palette: .fixed(pico8),         dither: 0.55),
        Style(id: "C64",        palette: .fixed(c64),           dither: 0.55),
        Style(id: "NES",        palette: .fixed(nes),           dither: 0.45),
        Style(id: "ZX Spectrum",palette: .fixed(zxSpectrum),    dither: 0.70),
        Style(id: "CGA",        palette: .fixed(cga),           dither: 1.00),
        Style(id: "Vaporwave",  palette: .fixed(vaporwave),     dither: 0.60),
        Style(id: "1-bit",      palette: .fixed(oneBit),        dither: 1.00),
        Style(id: "Mono",       palette: .ramp(mono),           dither: 1.00),
        Style(id: "Sepia",      palette: .ramp(sepia),          dither: 0.90),
        Style(id: "Green CRT",  palette: .ramp(greenCRT),       dither: 0.90),
        Style(id: "Amber CRT",  palette: .ramp(amberCRT),       dither: 0.90),
        Style(id: "Virtual Boy",palette: .ramp(virtualBoy),     dither: 1.00),
        Style(id: "Thermal",    palette: .ramp(thermal),        dither: 0.70),
    ]
    static func stylize(_ surface: Surface, style: Style) -> Surface {
        switch style.palette {
        case .adaptive(let n): return quantize(surface, palette: medianCut(surface.pixels, into: max(2,n)), dither: style.dither)
        case .fixed(let p):    return quantize(surface, palette: p, dither: style.dither)
        case .ramp(let r):     return rampMap(surface, ramp: r, dither: style.dither)
        }
    }
    static func quantize(_ surface: Surface, palette: [PixelRGB], dither: Double) -> Surface {
        guard palette.count > 1 else { return surface }
        let amp = dither * averageNearestDistance(palette)
        var out = surface.pixels
        for y in 0..<surface.height { for x in 0..<surface.width {
            let i = y*surface.width + x, p = surface.pixels[i]
            let t = (bayer8[y & 7][x & 7] - 0.5) * amp
            out[i] = nearest(in: palette, r: clampByte(Double(p.red)+t),
                             g: clampByte(Double(p.green)+t), b: clampByte(Double(p.blue)+t))
        } }
        return Surface(width: surface.width, height: surface.height, pixels: out)
    }
    static func rampMap(_ surface: Surface, ramp: [PixelRGB], dither: Double) -> Surface {
        guard ramp.count > 1 else { return surface }
        let n = ramp.count
        var out = surface.pixels
        for y in 0..<surface.height { for x in 0..<surface.width {
            let i = y*surface.width + x, p = surface.pixels[i]
            let l = (0.299*Double(p.red)+0.587*Double(p.green)+0.114*Double(p.blue))/255.0
            let pos = l*Double(n-1) + (bayer8[y & 7][x & 7] - 0.5)*dither
            out[i] = ramp[max(0, min(n-1, Int(pos.rounded())))]
        } }
        return Surface(width: surface.width, height: surface.height, pixels: out)
    }
    static func rgb(_ hex: UInt32) -> PixelRGB { PixelRGB(red: UInt8((hex>>16)&0xFF), green: UInt8((hex>>8)&0xFF), blue: UInt8(hex&0xFF)) }
    static let gameBoy = [0x0F380F,0x306230,0x8BAC0F,0x9BBC0F].map { rgb(UInt32($0)) }
    static let pico8 = [0x000000,0x1D2B53,0x7E2553,0x008751,0xAB5236,0x5F574F,0xC2C3C7,0xFFF1E8,0xFF004D,0xFFA300,0xFFEC27,0x00E436,0x29ADFF,0x83769C,0xFF77A8,0xFFCCAA].map { rgb(UInt32($0)) }
    static let c64 = [0x000000,0xFFFFFF,0x880000,0xAAFFEE,0xCC44CC,0x00CC55,0x0000AA,0xEEEE77,0xDD8855,0x664400,0xFF7777,0x333333,0x777777,0xAAFF66,0x0088FF,0xBBBBBB].map { rgb(UInt32($0)) }
    static let cga = [0x000000,0x55FFFF,0xFF55FF,0xFFFFFF].map { rgb(UInt32($0)) }
    static let oneBit = [0x000000,0xFFFFFF].map { rgb(UInt32($0)) }
    static let nes = [0x7C7C7C,0x0000FC,0x0000BC,0x4428BC,0x940084,0xA80020,0xA81000,0x881400,0x503000,0x007800,0x006800,0x005800,0x004058,0x000000,0xBCBCBC,0x0078F8,0x0058F8,0x6844FC,0xD800CC,0xE40058,0xF83800,0xE45C10,0xAC7C00,0x00B800,0x00A800,0x00A844,0x008888,0xF8F8F8,0x3CBCFC,0x6888FC,0x9878F8,0xF878F8,0xF85898,0xF87858,0xFCA044,0xF8B800,0xB8F818,0x58D854,0x58F898,0x00E8D8,0x787878,0xFCFCFC,0xA4E4FC,0xB8B8F8,0xD8B8F8,0xF8B8F8,0xF8A4C0,0xF0D0B0,0xFCE0A8,0xF8D878,0xD8F878,0xB8F8B8,0xB8F8D8,0x00FCFC,0xF8D8F8].map { rgb(UInt32($0)) }
    static let zxSpectrum = [0x000000,0x0000D7,0xD70000,0xD700D7,0x00D700,0x00D7D7,0xD7D700,0xD7D7D7,0x0000FF,0xFF0000,0xFF00FF,0x00FF00,0x00FFFF,0xFFFF00,0xFFFFFF].map { rgb(UInt32($0)) }
    static let vaporwave = [0x1A0033,0x5B2A86,0xC774E8,0xFF6AD5,0x8DDFFF,0x01CDFE,0x05FFA1,0xFFF5F5].map { rgb(UInt32($0)) }
    static let mono = [0x000000,0x555555,0xAAAAAA,0xFFFFFF].map { rgb(UInt32($0)) }
    static let sepia = [0x1A1208,0x4A3420,0x8A6A42,0xC8A878,0xF5E8C8].map { rgb(UInt32($0)) }
    static let greenCRT = [0x001B00,0x00451A,0x00873E,0x33CC55,0x88FF88].map { rgb(UInt32($0)) }
    static let amberCRT = [0x180A00,0x4A2A00,0x9A6400,0xE0A000,0xFFD060,0xFFF0C0].map { rgb(UInt32($0)) }
    static let virtualBoy = [0x000000,0x550000,0xAA0000,0xFF0000].map { rgb(UInt32($0)) }
    static let thermal = [0x000008,0x1A0A4A,0x6A1B9A,0xD6336C,0xFF6B1A,0xFFD000,0xFFFFFF].map { rgb(UInt32($0)) }
    static func medianCut(_ pixels: [PixelRGB], into count: Int) -> [PixelRGB] {
        guard !pixels.isEmpty else { return [] }
        var boxes = [pixels]
        while boxes.count < count {
            guard let idx = widestBoxIndex(boxes) else { break }
            let ch = widestChannel(boxes[idx])
            let sorted = boxes[idx].sorted { component($0, ch) < component($1, ch) }
            let mid = sorted.count/2
            boxes[idx] = Array(sorted[..<mid]); boxes.append(Array(sorted[mid...]))
        }
        return boxes.compactMap(average)
    }
    static func widestBoxIndex(_ boxes: [[PixelRGB]]) -> Int? {
        var best: Int?; var bestRange = 0
        for (i, box) in boxes.enumerated() where box.count > 1 {
            let r = channelRange(box); if best == nil || r > bestRange { best = i; bestRange = r } }
        return best
    }
    static func bounds(_ box: [PixelRGB]) -> (lo: [Int], hi: [Int]) {
        var lo = [255,255,255], hi = [0,0,0]
        for p in box { let c = [Int(p.red), Int(p.green), Int(p.blue)]
            for k in 0..<3 { lo[k] = min(lo[k], c[k]); hi[k] = max(hi[k], c[k]) } }
        return (lo, hi)
    }
    static func channelRange(_ box: [PixelRGB]) -> Int { let (lo,hi)=bounds(box); return max(hi[0]-lo[0], max(hi[1]-lo[1], hi[2]-lo[2])) }
    static func widestChannel(_ box: [PixelRGB]) -> Int { let (lo,hi)=bounds(box); let r=[hi[0]-lo[0],hi[1]-lo[1],hi[2]-lo[2]]; var b=0; for k in 1..<3 where r[k]>r[b] { b=k }; return b }
    static func component(_ p: PixelRGB, _ ch: Int) -> UInt8 { ch==0 ? p.red : (ch==1 ? p.green : p.blue) }
    static func average(_ box: [PixelRGB]) -> PixelRGB? {
        guard !box.isEmpty else { return nil }
        var r=0,g=0,b=0; for p in box { r+=Int(p.red); g+=Int(p.green); b+=Int(p.blue) }
        let n=box.count; return PixelRGB(red: UInt8(r/n), green: UInt8(g/n), blue: UInt8(b/n))
    }
    static func nearest(in palette: [PixelRGB], r: UInt8, g: UInt8, b: UInt8) -> PixelRGB {
        let R=Int(r),G=Int(g),B=Int(b); var best=palette[0], bestD=Int.max
        for c in palette { let dr=R-Int(c.red),dg=G-Int(c.green),db=B-Int(c.blue); let d=dr*dr+dg*dg+db*db; if d<bestD { bestD=d; best=c } }
        return best
    }
    static func averageNearestDistance(_ p: [PixelRGB]) -> Double {
        var total = 0.0
        for i in 0..<p.count { var best = Double.greatestFiniteMagnitude
            for j in 0..<p.count where j != i {
                let dr=Double(Int(p[i].red)-Int(p[j].red)), dg=Double(Int(p[i].green)-Int(p[j].green)), db=Double(Int(p[i].blue)-Int(p[j].blue))
                best = min(best, (dr*dr+dg*dg+db*db).squareRoot()) }
            total += best }
        return total / Double(p.count)
    }
    static func clampByte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }
    static let bayer8: [[Double]] = {
        let m: [[Int]] = [[0,32,8,40,2,34,10,42],[48,16,56,24,50,18,58,26],[12,44,4,36,14,46,6,38],[60,28,52,20,62,30,54,22],[3,35,11,43,1,33,9,41],[51,19,59,27,49,17,57,25],[15,47,7,39,13,45,5,37],[63,31,55,23,61,29,53,21]]
        return m.map { $0.map { Double($0)/64.0 } }
    }()
}

func writePNG(_ s: Surface, _ scale: Int, _ path: String) {
    let w=s.width*scale, h=s.height*scale; var buf=[UInt8](repeating:0,count:w*h*4)
    for y in 0..<h { for x in 0..<w { let sp=s.pixels[(y/scale)*s.width+(x/scale)]; let o=(y*w+x)*4
        buf[o]=sp.red; buf[o+1]=sp.green; buf[o+2]=sp.blue; buf[o+3]=255 } }
    let ctx=CGContext(data:&buf,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img=ctx.makeImage()!
    let d=CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(d,img,nil); CGImageDestinationFinalize(d)
}

// A synthetic "album cover": smooth multi-hue gradients (the hard case for quantization —
// shows banding vs. dithering) plus a couple of saturated discs and a soft sky-to-ground fade.
func syntheticCover(_ size: Int) -> Surface {
    func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v*255).rounded()))) }
    func mix(_ a: (Double,Double,Double), _ b: (Double,Double,Double), _ t: Double) -> (Double,Double,Double) {
        (a.0+(b.0-a.0)*t, a.1+(b.1-a.1)*t, a.2+(b.2-a.2)*t)
    }
    var px = [PixelRGB]()
    let top=(0.05,0.02,0.18), horizon=(0.95,0.35,0.15), ground=(0.10,0.02,0.12)
    for y in 0..<size { for x in 0..<size {
        let v = Double(y)/Double(size), u = Double(x)/Double(size)
        var c = v < 0.6 ? mix(top, horizon, pow(v/0.6, 1.5)) : mix(horizon, ground, (v-0.6)/0.4)
        // sun disc
        let dx=u-0.5, dy=v-0.42, r=(dx*dx+dy*dy).squareRoot()
        if r < 0.22 { c = mix((1,0.92,0.6),(1,0.45,0.2), min(1, r/0.22)); c = mix(c, c, 0) }
        // cool accent disc
        let dx2=u-0.78, dy2=v-0.30, r2=(dx2*dx2+dy2*dy2).squareRoot()
        if r2 < 0.12 { c = mix(c, (0.2,0.8,1.0), 0.7*(1 - r2/0.12)) }
        px.append(PixelRGB(red: byte(c.0), green: byte(c.1), blue: byte(c.2)))
    } }
    return Surface(width: size, height: size, pixels: px)
}

let args = CommandLine.arguments
let base: Surface
if args.count > 1 && args[1] == "synthetic" {
    base = syntheticCover(64)
} else if args.count > 1, let s = loadSurface(args[1], size: 64) {
    base = s
} else {
    print("usage: papreview <image|synthetic> [outDir]"); exit(1)
}
let outDir = args.count > 2 ? args[2] : "/tmp/preview"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let enhanced = punchUp(base)
let scale = 8
writePNG(enhanced, scale, "\(outDir)/pa_00_Off.png")
for (i, style) in PixelArt.presets.enumerated() {
    let safe = style.id.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "")
    writePNG(PixelArt.stylize(enhanced, style: style), scale, "\(outDir)/pa_\(String(format: "%02d", i+1))_\(safe).png")
}
print("wrote pixel-art previews to \(outDir)")
