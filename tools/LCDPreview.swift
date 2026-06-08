// LCD 7-segment digit design sandbox → PNGs. Self-contained.
//   swiftc -O tools/LCDPreview.swift -o /tmp/lcdpreview && /tmp/lcdpreview /tmp/preview
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PixelRGB: Equatable { var red: UInt8, green: UInt8, blue: UInt8 }
struct Surface {
    let width: Int, height: Int; var pixels: [PixelRGB]
    init(_ w: Int, _ h: Int, _ fill: PixelRGB = PixelRGB(red:0,green:0,blue:0)) { width=w;height=h;pixels=Array(repeating:fill,count:w*h) }
    mutating func set(_ x: Int,_ y: Int,_ c: PixelRGB){ if x>=0,x<width,y>=0,y<height { pixels[y*width+x]=c } }
    func at(_ x: Int,_ y: Int)->PixelRGB{ pixels[y*width+x] }
}
func byte(_ v: Double)->UInt8{ UInt8(max(0,min(255,(v*255).rounded()))) }
func mix(_ a: PixelRGB,_ b: PixelRGB,_ t: Double)->PixelRGB{ func l(_ x:UInt8,_ y:UInt8)->UInt8{byte((Double(x)*(1-t)+Double(y)*t)/255)}; return PixelRGB(red:l(a.red,b.red),green:l(a.green,b.green),blue:l(a.blue,b.blue)) }
func darken(_ c: PixelRGB,_ f: Double)->PixelRGB{ PixelRGB(red:byte(Double(c.red)/255*f),green:byte(Double(c.green)/255*f),blue:byte(Double(c.blue)/255*f)) }
func vivid(_ c: PixelRGB)->PixelRGB{ var r=Double(c.red)/255,g=Double(c.green)/255,b=Double(c.blue)/255; let mx=max(r,g,b),mn=min(r,g,b); if mx<0.04 {return PixelRGB(red:120,green:180,blue:255)}; let mid=(mx+mn)/2,s=1.6; r=mid+(r-mid)*s;g=mid+(g-mid)*s;b=mid+(b-mid)*s; let sc=0.95/mx; return PixelRGB(red:byte(r*sc),green:byte(g*sc),blue:byte(b*sc)) }

// ---------- 7-segment LCD ----------
enum LCD {
    // segments a,b,c,d,e,f,g
    static let map: [Int:[Bool]] = [
        0:[true,true,true,true,true,true,false], 1:[false,true,true,false,false,false,false],
        2:[true,true,false,true,true,false,true], 3:[true,true,true,true,false,false,true],
        4:[false,true,true,false,false,true,true], 5:[true,false,true,true,false,true,true],
        6:[true,false,true,true,true,true,true], 7:[true,true,true,false,false,false,false],
        8:[true,true,true,true,true,true,true], 9:[true,true,true,true,false,true,true]
    ]
    enum Tok { case digit(Int), colon }
    static func tokens(_ date: Date,_ cal: Calendar,_ h24: Bool)->[Tok]{
        let c=cal.dateComponents([.hour,.minute],from:date); var h=c.hour ?? 0
        if !h24 { h%=12; if h==0 {h=12} }; let m=c.minute ?? 0
        let h1=h/10,h2=h%10,m1=m/10,m2=m%10
        var t:[Tok]=[]; if h24||h1 != 0 {t.append(.digit(h1))}; t.append(.digit(h2)); t.append(.colon); t.append(.digit(m1)); t.append(.digit(m2)); return t
    }

    /// Render the time onto `s` (composited over its background). `lit`/`ghost` style an LCD.
    static func draw(into s: inout Surface, date: Date, accent: PixelRGB, topY: Int, height dh: Double,
                     calendar: Calendar = .current, use24Hour: Bool = false) {
        let size = s.width, ss = 8, dim = size*ss
        guard let ctx = CGContext(data:nil,width:dim,height:dim,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setShouldAntialias(true); ctx.scaleBy(x:CGFloat(ss),y:CGFloat(ss))
        // CG is y-up; we author in top-down coords, so flip.
        ctx.translateBy(x:0,y:CGFloat(size)); ctx.scaleBy(x:1,y:-1)
        let cs = CGColorSpaceCreateDeviceRGB()
        func cg(_ c: PixelRGB,_ a: Double)->CGColor{ CGColor(colorSpace:cs,components:[Double(c.red)/255,Double(c.green)/255,Double(c.blue)/255,a])! }

        let dw = 12.0, t = 3.0, gap = 1.0, colonW = 5.0
        let toks = tokens(date, calendar, use24Hour)
        func tw(_ tk: Tok)->Double{ if case .colon = tk { return colonW }; return dw }
        let total = toks.map(tw).reduce(0,+) + gap*Double(toks.count-1)
        var x = (Double(size) - total)/2
        let oy = Double(topY)
        let skew = 1.6   // px of lean across the digit height

        // hexagonal segment paths (with a small inset so segments don't touch)
        func shear(_ px: Double,_ py: Double)->CGPoint{ CGPoint(x: px + skew*(1 - (py-oy)/dh), y: py) }
        func hbar(_ ox: Double,_ yc: Double,_ w: Double)->CGPath{
            let p=CGMutablePath(), i=0.6
            let pts=[(ox+t*0.5+i,yc),(ox+t+i,yc-t*0.5),(ox+w-t-i,yc-t*0.5),(ox+w-t*0.5-i,yc),(ox+w-t-i,yc+t*0.5),(ox+t+i,yc+t*0.5)]
            p.move(to:shear(pts[0].0,pts[0].1)); for k in 1..<pts.count { p.addLine(to:shear(pts[k].0,pts[k].1)) }; p.closeSubpath(); return p
        }
        func vbar(_ xc: Double,_ oyy: Double,_ h: Double)->CGPath{
            let p=CGMutablePath(), i=0.6
            let pts=[(xc,oyy+t*0.5+i),(xc+t*0.5,oyy+t+i),(xc+t*0.5,oyy+h-t-i),(xc,oyy+h-t*0.5-i),(xc-t*0.5,oyy+h-t-i),(xc-t*0.5,oyy+t+i)]
            p.move(to:shear(pts[0].0,pts[0].1)); for k in 1..<pts.count { p.addLine(to:shear(pts[k].0,pts[k].1)) }; p.closeSubpath(); return p
        }
        func segPaths(_ ox: Double)->[CGPath]{
            [ hbar(ox, oy+t*0.5, dw),                 // a
              vbar(ox+dw-t*0.5, oy, dh/2+t*0.5),      // b
              vbar(ox+dw-t*0.5, oy+dh/2-t*0.5, dh/2+t*0.5), // c
              hbar(ox, oy+dh-t*0.5, dw),              // d
              vbar(ox+t*0.5, oy+dh/2-t*0.5, dh/2+t*0.5),    // e
              vbar(ox+t*0.5, oy, dh/2+t*0.5),         // f
              hbar(ox, oy+dh/2, dw) ]                 // g
        }

        let ghost = vivid(accent)
        let litCore = mix(PixelRGB(red:255,green:255,blue:255), vivid(accent), 0.18)
        let litGlow = vivid(accent)
        for tk in toks {
            switch tk {
            case .digit(let d):
                let segs = segPaths(x), on = map[d]!
                // ghost (all segments, faint)
                for p in segs { ctx.addPath(p) }; ctx.setFillColor(cg(ghost,0.12)); ctx.fillPath()
                // glow under lit
                let litPath=CGMutablePath(); for (k,p) in segs.enumerated() where on[k] { litPath.addPath(p) }
                ctx.addPath(litPath); ctx.setStrokeColor(cg(litGlow,0.5)); ctx.setLineWidth(2.2); ctx.setLineJoin(.round); ctx.strokePath()
                ctx.addPath(litPath); ctx.setFillColor(cg(litCore,1)); ctx.fillPath()
                x += dw + gap
            case .colon:
                let cxp = x + colonW/2, r = t*0.55
                for cy in [oy+dh*0.34, oy+dh*0.66] {
                    let rect = CGRect(x: shear(cxp,cy).x - r, y: cy - r, width: r*2, height: r*2)
                    ctx.addEllipse(in: rect); ctx.setFillColor(cg(ghost,0.12)); ctx.fillPath()
                    ctx.addEllipse(in: rect); ctx.setStrokeColor(cg(litGlow,0.5)); ctx.setLineWidth(2.0); ctx.strokePath()
                    ctx.addEllipse(in: rect); ctx.setFillColor(cg(litCore,1)); ctx.fillPath()
                }
                x += colonW + gap
            }
        }

        guard let img = ctx.makeImage() else { return }
        let bpr=size*4; var buf=[UInt8](repeating:0,count:bpr*size)
        guard let dctx=CGContext(data:&buf,width:size,height:size,bitsPerComponent:8,bytesPerRow:bpr,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        dctx.interpolationQuality = .high; dctx.draw(img,in:CGRect(x:0,y:0,width:size,height:size))
        for y in 0..<size { for xx in 0..<size {
            let o=y*bpr+xx*4; let a=Double(buf[o+3])/255
            if a<=0.003 { continue }
            // premultiplied over bg
            let base = s.at(xx,y)
            s.set(xx,y, PixelRGB(red: byte(Double(buf[o])/255 + Double(base.red)/255*(1-a)),
                                 green: byte(Double(buf[o+1])/255 + Double(base.green)/255*(1-a)),
                                 blue: byte(Double(buf[o+2])/255 + Double(base.blue)/255*(1-a))))
        }}
    }
}

// ---------- backgrounds (reused from the hero design) ----------
func synthwave(_ s: inout Surface, _ accent: PixelRGB, _ titleBand: Int) {
    let size=s.width, horizon=Int(Double(size)*0.60)
    let skyTop=PixelRGB(red:14,green:6,blue:34), skyH=mix(PixelRGB(red:90,green:20,blue:90),accent,0.35)
    for y in 0..<horizon { for x in 0..<size { s.set(x,y,mix(skyTop,skyH,pow(Double(y)/Double(horizon),1.6))) } }
    let sunR=Double(size)*0.26, sx=Double(size)/2, sy=Double(horizon)-sunR*0.35
    let sunTop=PixelRGB(red:255,green:240,blue:180), sunBot=vivid(mix(accent,PixelRGB(red:255,green:60,blue:140),0.5))
    for y in 0..<horizon { for x in 0..<size { let dx=Double(x)-sx,dy=Double(y)-sy; if dx*dx+dy*dy<=sunR*sunR { let tt=(Double(y)-(sy-sunR))/(2*sunR); var c=mix(sunTop,sunBot,max(0,min(1,tt))); let below=Double(y)-sy; if below>0 { let per=max(2,Int(2.0+(1-below/sunR)*5.0)); if Int(below)%per==0 {c=darken(c,0.15)} }; s.set(x,y,c) } } }
    for y in horizon..<size { for x in 0..<size { s.set(x,y,mix(PixelRGB(red:18,green:6,blue:30),PixelRGB(red:4,green:2,blue:10),Double(y-horizon)/Double(size-horizon))) } }
    let grid=vivid(accent); var i=0
    while true { let y=horizon+Int(pow(Double(i)/10.0,1.8)*Double(size-horizon)); if y>=size {break}; for x in 0..<size { s.set(x,y,mix(s.at(x,y),grid,0.55)) }; i+=1 }
    for k in -7...7 { for y in horizon..<size { let p=Double(y-horizon)/Double(size-horizon); let xx=Int(Double(size)/2+Double(k)*p*(Double(size)*0.16)); if xx>=0,xx<size { s.set(xx,y,mix(s.at(xx,y),grid,0.35)) } } }
    for y in (size-titleBand)..<size { for x in 0..<size { let f=Double(y-(size-titleBand)+1)/Double(titleBand); s.set(x,y,darken(s.at(x,y),1-0.7*f)) } }
}
func fakeArt(_ size: Int,_ style: Int)->Surface{ var s=Surface(size,size); for y in 0..<size { for x in 0..<size { let u=Double(x)/Double(size),v=Double(y)/Double(size); var c:PixelRGB; if style==0 { c=mix(PixelRGB(red:250,green:180,blue:60),PixelRGB(red:200,green:30,blue:90),v); c=mix(c,PixelRGB(red:40,green:10,blue:70),pow(v,2)) } else { c=mix(PixelRGB(red:0,green:190,blue:200),PixelRGB(red:120,green:30,blue:200),(u+v)/2) }; s.set(x,y,c) } }; let cxs=[Double(size)*0.30,Double(size)*0.72],cys=[Double(size)*0.35,Double(size)*0.66],cols=[PixelRGB(red:255,green:240,blue:200),PixelRGB(red:30,green:200,blue:255)]; for j in 0..<2 { for y in 0..<size { for x in 0..<size { let dx=Double(x)-cxs[j],dy=Double(y)-cys[j],r=Double(size)*0.16; if dx*dx+dy*dy<r*r { s.set(x,y,mix(s.at(x,y),cols[j],0.5)) } } } }; return s }
func artBg(_ s: inout Surface,_ art: Surface,_ accent: PixelRGB,_ titleBand: Int){ let size=s.width,cx=Double(size)/2,cy=Double(size)/2,maxd=(Double(size)/2)*1.18; for y in 0..<size { for x in 0..<size { var c=darken(art.at(x,y),0.42); let d=(((Double(x)-cx)*(Double(x)-cx)+(Double(y)-cy)*(Double(y)-cy)).squareRoot())/maxd; c=darken(c,1-min(0.6,d*0.6)); let into=y-(size-titleBand); if into > -2 { let f=min(1.0,Double(into+2)/Double(titleBand)); c=darken(c,1-0.72*f) }; s.set(x,y,c) } } }

func hero(_ date: Date,_ accent: PixelRGB,_ art: Surface?,_ ticker: String,_ scroll: Int)->Surface{
    let size=64, titleBand=16; var s=Surface(size,size)
    if let art { artBg(&s,art,accent,titleBand) } else { synthwave(&s,accent,titleBand) }
    LCD.draw(into:&s,date:date,accent:accent,topY:5,height:26)
    _ = (ticker, scroll)   // native text drawn on the device, not here
    return s
}

func writePNG(_ surface: Surface,_ scale: Int,_ path: String){ let w=surface.width*scale,h=surface.height*scale; var buf=[UInt8](repeating:0,count:w*h*4); for y in 0..<h { for x in 0..<w { let sp=surface.pixels[(y/scale)*surface.width+(x/scale)]; let o=(y*w+x)*4; buf[o]=sp.red;buf[o+1]=sp.green;buf[o+2]=sp.blue;buf[o+3]=255 } }; let cs=CGColorSpaceCreateDeviceRGB(); let ctx=CGContext(data:&buf,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!; let img=ctx.makeImage()!; let d=CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL,UTType.png.identifier as CFString,1,nil)!; CGImageDestinationAddImage(d,img,nil); CGImageDestinationFinalize(d) }

let outDir = CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "/tmp/preview"
try? FileManager.default.createDirectory(atPath:outDir,withIntermediateDirectories:true)
let cal=Calendar(identifier:.gregorian)
func date(_ h:Int,_ m:Int)->Date{ var c=DateComponents();c.year=2026;c.month=6;c.day=7;c.hour=h;c.minute=m;c.second=30; return cal.date(from:c)! }
let teal=vivid(PixelRGB(red:0,green:200,blue:180)), amber=vivid(PixelRGB(red:255,green:170,blue:40))
writePNG(hero(date(10,9), teal, nil, "", 0), 8, "\(outDir)/lcd_synthwave.png")
writePNG(hero(date(12,34), amber, nil, "", 0), 8, "\(outDir)/lcd_synthwave2.png")
writePNG(hero(date(1,51), vivid(PixelRGB(red:240,green:90,blue:70)), fakeArt(64,0), "", 0), 8, "\(outDir)/lcd_art_warm.png")
writePNG(hero(date(10,9), vivid(PixelRGB(red:40,green:200,blue:220)), fakeArt(64,1), "", 0), 8, "\(outDir)/lcd_art_cool.png")
// plain dark background to judge the pure LCD aesthetic
var plain=Surface(64,64,PixelRGB(red:6,green:8,blue:12)); LCD.draw(into:&plain,date:date(12,34),accent:teal,topY:18,height:28); writePNG(plain,8,"\(outDir)/lcd_plain.png")
print("wrote LCD previews to \(outDir)")
