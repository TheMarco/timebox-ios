// Design sandbox for the Weather module's 64×64 scenes. Self-contained (no TimeboxKit).
// Renders a contact sheet of conditions so the look can be iterated WITHOUT the device.
//   swiftc -O tools/WeatherPreview.swift -o /tmp/wx && /tmp/wx /tmp/wx.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PixelRGB { var r: Double; var g: Double; var b: Double
    init(_ r: Double,_ g: Double,_ b: Double){ self.r=r; self.g=g; self.b=b }
    init(_ r: Int,_ g: Int,_ b: Int){ self.r=Double(r)/255; self.g=Double(g)/255; self.b=Double(b)/255 }
}
func mix(_ a: PixelRGB,_ b: PixelRGB,_ t: Double)->PixelRGB{ let t=max(0,min(1,t)); return PixelRGB(a.r+(b.r-a.r)*t,a.g+(b.g-a.g)*t,a.b+(b.b-a.b)*t) }
func screenc(_ a: PixelRGB,_ b: PixelRGB,_ amt: Double)->PixelRGB{ let m=max(0,min(1,amt)); return PixelRGB(1-(1-a.r)*(1-b.r*m),1-(1-a.g)*(1-b.g*m),1-(1-a.b)*(1-b.b*m)) }

// Big (supersampled) canvas
final class Canvas {
    let W: Int; var px: [PixelRGB]
    init(_ w: Int,_ fill: PixelRGB){ W=w; px=Array(repeating: fill, count: w*w) }
    func at(_ x: Int,_ y: Int)->PixelRGB{ px[y*W+x] }
    func set(_ x: Int,_ y: Int,_ c: PixelRGB){ if x>=0,x<W,y>=0,y<W { px[y*W+x]=c } }
    func over(_ x: Int,_ y: Int,_ c: PixelRGB,_ a: Double){ if x>=0,x<W,y>=0,y<W { px[y*W+x]=mix(px[y*W+x],c,a) } }
    func screen(_ x: Int,_ y: Int,_ c: PixelRGB,_ a: Double){ if x>=0,x<W,y>=0,y<W { px[y*W+x]=screenc(px[y*W+x],c,a) } }
}

// Soft-edged filled disc (AA via coverage from the supersampling itself + a 1px feather)
func disc(_ cv: Canvas,_ cx: Double,_ cy: Double,_ r: Double,_ c: PixelRGB,_ a: Double = 1){
    let x0=Int(cx-r-1), x1=Int(cx+r+1), y0=Int(cy-r-1), y1=Int(cy+r+1)
    for y in y0...y1 { for x in x0...x1 {
        let d=(Double(x)+0.5-cx)*(Double(x)+0.5-cx)+(Double(y)+0.5-cy)*(Double(y)+0.5-cy)
        let dist=d.squareRoot(); let cov=max(0,min(1,(r-dist+0.5)))
        if cov>0 { cv.over(x,y,c,a*cov) }
    }}
}
func glow(_ cv: Canvas,_ cx: Double,_ cy: Double,_ r: Double,_ c: PixelRGB,_ strength: Double){
    let x0=Int(cx-r), x1=Int(cx+r), y0=Int(cy-r), y1=Int(cy+r)
    for y in y0...y1 { for x in x0...x1 {
        let dist=((Double(x)+0.5-cx)*(Double(x)+0.5-cx)+(Double(y)+0.5-cy)*(Double(y)+0.5-cy)).squareRoot()
        if dist<r { let f=pow(1-dist/r,2.2); cv.screen(x,y,c,strength*f) }
    }}
}
func line(_ cv: Canvas,_ x0: Double,_ y0: Double,_ x1: Double,_ y1: Double,_ w: Double,_ c: PixelRGB,_ a: Double = 1){
    let steps=Int(max(abs(x1-x0),abs(y1-y0)))+1
    for i in 0...steps { let t=Double(i)/Double(steps); disc(cv, x0+(x1-x0)*t, y0+(y1-y0)*t, w/2, c, a) }
}

// A fluffy cloud = union of discs, with a darker underside.
func cloud(_ cv: Canvas,_ cx: Double,_ cy: Double,_ scale: Double,_ top: PixelRGB,_ bot: PixelRGB){
    let lobes: [(Double,Double,Double)] = [(-2.2,0.2,1.0),(-0.9,-0.7,1.35),(0.7,-0.8,1.25),(2.1,0.1,1.0),(0.2,0.4,1.5)]
    for (dx,dy,r) in lobes { disc(cv, cx+dx*scale, cy+dy*scale, r*scale, bot) }       // underside
    for (dx,dy,r) in lobes { disc(cv, cx+dx*scale, cy-0.45*scale+dy*scale, r*scale*0.92, top) } // top highlight
}

// ---- 5×7 temperature digits ----
let DIG: [[String]] = [
 [".###.","#...#","#...#","#...#","#...#","#...#",".###."],
 ["..#..",".##..","..#..","..#..","..#..","..#..",".###."],
 [".###.","#...#","....#","...#.","..#..",".#...","#####"],
 ["####.","....#","....#",".###.","....#","....#","####."],
 ["...#.","..##.",".#.#.","#..#.","#####","...#.","...#."],
 ["#####","#....","####.","....#","....#","#...#",".###."],
 [".###.","#....","#....","####.","#...#","#...#",".###."],
 ["#####","....#","...#.","..#..",".#...",".#...",".#..."],
 [".###.","#...#","#...#",".###.","#...#","#...#",".###."],
 [".###.","#...#","#...#",".####","....#","....#",".###."]]
// 3×5 small digits
let SM: [[String]] = [
 ["###","#.#","#.#","#.#","###"],["..#","..#","..#","..#","..#"],["###","..#","###","#..","###"],
 ["###","..#","###","..#","###"],["#.#","#.#","###","..#","..#"],["###","#..","###","..#","###"],
 ["###","#..","###","#.#","###"],["###","..#","..#","..#","..#"],["###","#.#","###","#.#","###"],["###","#.#","###","..#","###"]]

struct Surf { var px=[PixelRGB](repeating: PixelRGB(0,0,0), count: 64*64)
    mutating func set(_ x: Int,_ y: Int,_ c: PixelRGB){ if x>=0,x<64,y>=0,y<64 { px[y*64+x]=c } }
    func at(_ x: Int,_ y: Int)->PixelRGB{ px[y*64+x] }
}
func bigDigit(_ s: inout Surf,_ d: Int,_ ox: Int,_ oy: Int,_ sc: Int,_ c: PixelRGB){
    for (r,row) in DIG[d].enumerated(){ for (i,ch) in row.enumerated() where ch=="#" {
        for sy in 0..<sc { for sx in 0..<sc {
            let x=ox+i*sc+sx, y=oy+r*sc+sy
            s.set(x+1,y+1, mix(s.at(x+1,y+1), PixelRGB(0,0,0), 0.55))  // soft shadow
            s.set(x,y,c)
        }}
    }}
}
func smallNum(_ s: inout Surf,_ v: Int,_ ox: Int,_ oy: Int,_ c: PixelRGB){
    let str=String(v); var x=ox
    for ch in str { let d=Int(String(ch))!; for (r,row) in SM[d].enumerated(){ for (i,p) in row.enumerated() where p=="#" { s.set(x+i,oy+r, c) } }; x+=4 }
}
func tempWidth(_ v: Int,_ sc: Int)->Int{ String(abs(v)).count*(5*sc+sc) - sc + (4*sc) }  // digits + degree ring

func drawTemp(_ s: inout Surf,_ v: Int,_ cyCenter: Int,_ c: PixelRGB){
    let sc=2; let str=String(v); let dw=5*sc, gap=sc, degW=4*sc
    let total = str.count*(dw+gap) - gap + sc + degW
    var x = (64 - total)/2; let y = cyCenter - (7*sc)/2
    for ch in str { bigDigit(&s, Int(String(ch))!, x, y, sc, c); x += dw+gap }
    // degree ring
    x += sc
    for yy in 0..<degW { for xx in 0..<degW {
        let dx=Double(xx)-Double(degW)/2+0.5, dy=Double(yy)-Double(degW)/2+0.5, d=(dx*dx+dy*dy).squareRoot()
        if d<Double(degW)/2 && d>Double(degW)/2-1.6 { s.set(x+xx, y+yy, c) }
    }}
}

// ---- the scene ----
func skyColors(_ cond: Int,_ day: Bool) -> (PixelRGB,PixelRGB) {
    switch cond {
    case 0: return day ? (PixelRGB(36,110,214),PixelRGB(150,205,250)) : (PixelRGB(8,10,34),PixelRGB(30,38,86))   // clear
    case 1: return day ? (PixelRGB(54,120,200),PixelRGB(168,200,236)) : (PixelRGB(12,14,38),PixelRGB(40,48,90))  // partly
    case 2: return (PixelRGB(92,104,126),PixelRGB(150,160,180))                                                  // cloudy
    case 3: return (PixelRGB(120,126,138),PixelRGB(168,172,182))                                                 // fog
    case 4: return (PixelRGB(48,60,86),PixelRGB(96,108,134))                                                     // rain
    case 5: return (PixelRGB(120,132,158),PixelRGB(178,190,212))                                                 // snow
    default: return (PixelRGB(22,22,40),PixelRGB(58,58,86))                                                      // thunder
    }
}
func weather(_ cond: Int,_ day: Bool,_ temp: Int,_ hi: Int,_ lo: Int,_ phase: Double) -> Surf {
    let ss=4, W=64*ss
    let (top,bot)=skyColors(cond,day)
    let cv=Canvas(W, top)
    for y in 0..<W { let c=mix(top,bot,pow(Double(y)/Double(W-1),0.9)); for x in 0..<W { cv.px[y*W+x]=c } }
    func P(_ v: Double)->Double{ v*Double(ss) }
    let icx=P(32), icy=P(20)

    func sun(_ cx: Double,_ cy: Double,_ r: Double){
        glow(cv, cx, cy, r*3.2, PixelRGB(255,236,150), 0.9)
        for k in 0..<12 { let ang=phase*0.4 + Double(k)*Double.pi/6
            line(cv, cx+cos(ang)*r*1.5, cy+sin(ang)*r*1.5, cx+cos(ang)*r*2.1, cy+sin(ang)*r*2.1, P(1.4), PixelRGB(255,224,120), 0.9) }
        disc(cv, cx, cy, r*1.12, PixelRGB(255,210,90)); disc(cv, cx, cy, r, PixelRGB(255,238,170))
    }
    func moon(_ cx: Double,_ cy: Double,_ r: Double){
        glow(cv, cx, cy, r*2.4, PixelRGB(180,200,255), 0.5)
        disc(cv, cx, cy, r, PixelRGB(235,240,255)); disc(cv, cx+r*0.55, cy-r*0.35, r*0.92, mix(top,bot,0.3))  // crescent carve
    }
    func stars(){ for k in 0..<26 { let sx=Double((k*53)%64), sy=Double((k*29)%34)
        let tw=0.5+0.5*sin(phase*2+Double(k)); disc(cv, P(sx), P(sy), P(0.5), PixelRGB(255,255,255), 0.5*tw) } }
    func rain(_ n: Int,_ col: PixelRGB){ for k in 0..<n {
        let bx=Double((k*37)%64), off=(phase*40+Double((k*53)%64)).truncatingRemainder(dividingBy: 64)
        let y=18+off*0.7; line(cv, P(bx), P(y), P(bx-2), P(y+6), P(0.8), col, 0.75) } }
    func snow(_ n: Int){ for k in 0..<n {
        let bx=Double((k*41)%64), off=(phase*16+Double((k*59)%48)).truncatingRemainder(dividingBy: 48)
        let y=20+off, x=bx+2*sin(phase+Double(k)); disc(cv, P(x), P(y), P(1.0), PixelRGB(245,250,255), 0.9) } }
    func bolt(){ let flash=max(0, sin(phase*3))>0.9 ? 0.5 : 0.0
        if flash>0 { for i in 0..<cv.px.count { cv.px[i]=screenc(cv.px[i], PixelRGB(200,210,255), flash) } }
        var x=P(34), y=P(22); let segs=[(P(-5),P(7)),(P(4),P(6)),(P(-4),P(7)),(P(3),P(6))]
        for (dx,dy) in segs { line(cv, x, y, x+dx, y+dy, P(1.2), PixelRGB(255,240,150), 0.95); x+=dx; y+=dy } }
    func fog(){ for b in 0..<5 { let y=P(Double(14+b*8)); let off=sin(phase*0.6+Double(b))*P(6)
        for x in 0..<W { let a=0.18+0.10*sin(Double(x)/Double(W)*6+phase+Double(b)); cv.over(x,Int(y+off),PixelRGB(235,238,245),a); cv.over(x,Int(y+off)+1,PixelRGB(235,238,245),a*0.7) } } }

    switch cond {
    case 0: if day { sun(icx,icy,P(9)) } else { stars(); moon(icx,icy,P(8)) }
    case 1: if day { sun(P(22),P(16),P(7)) } else { stars(); moon(P(22),P(15),P(6)) }; cloud(cv,P(38),P(24),P(3.4), PixelRGB(245,248,255), PixelRGB(180,190,210))
    case 2: cloud(cv,P(22),P(18),P(3.0),PixelRGB(210,216,230),PixelRGB(150,158,178)); cloud(cv,P(40),P(26),P(4.0),PixelRGB(235,240,250),PixelRGB(170,178,196))
    case 3: cloud(cv,P(32),P(14),P(3.4),PixelRGB(215,220,228),PixelRGB(170,176,186)); fog()
    case 4: cloud(cv,P(32),P(16),P(4.2),PixelRGB(180,190,210),PixelRGB(120,130,154)); rain(34, PixelRGB(160,200,255))
    case 5: cloud(cv,P(32),P(16),P(4.2),PixelRGB(220,228,244),PixelRGB(160,172,196)); snow(26)
    default: cloud(cv,P(32),P(16),P(4.4),PixelRGB(120,124,150),PixelRGB(70,74,100)); rain(24, PixelRGB(150,170,220)); bolt()
    }

    // downsample
    var s=Surf(); let inv=1.0/Double(ss*ss)
    for oy in 0..<64 { for ox in 0..<64 {
        var r=0.0,g=0.0,b=0.0
        for dy in 0..<ss { for dx in 0..<ss { let p=cv.at(ox*ss+dx, oy*ss+dy); r+=p.r; g+=p.g; b+=p.b } }
        s.set(ox,oy, PixelRGB(r*inv,g*inv,b*inv))
    }}
    // temperature + hi/lo
    drawTemp(&s, temp, 46, PixelRGB(255,255,255))
    smallNum(&s, hi, 16, 56, PixelRGB(255,180,120)); smallNum(&s, lo, 40, 56, PixelRGB(150,190,255))
    return s
}

// ---- PNG contact sheet ----
func contactSheet(_ tiles: [Surf],_ cols: Int,_ scale: Int,_ gap: Int,_ path: String){
    let rows=(tiles.count+cols-1)/cols, t=64*scale, W=cols*t+(cols+1)*gap, H=rows*t+(rows+1)*gap
    var buf=[UInt8](repeating: 24, count: W*H*4)
    for (idx,tile) in tiles.enumerated(){ let r=idx/cols, c=idx%cols, ox=gap+c*(t+gap), oy=gap+r*(t+gap)
        for y in 0..<t { for x in 0..<t { let p=tile.at(x/scale,y/scale); let o=((oy+y)*W+ox+x)*4
            buf[o]=UInt8(max(0,min(255,p.r*255))); buf[o+1]=UInt8(max(0,min(255,p.g*255))); buf[o+2]=UInt8(max(0,min(255,p.b*255))); buf[o+3]=255 } }
    }
    let cs=CGColorSpaceCreateDeviceRGB()
    let ctx=CGContext(data:&buf,width:W,height:H,bitsPerComponent:8,bytesPerRow:W*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img=ctx.makeImage()!
    let dest=CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL, UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(dest,img,nil); CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "/tmp/wx.png"
let tiles=[
    weather(0,true,72,78,61,1.0), weather(0,false,58,72,55,1.0),
    weather(1,true,69,75,60,1.0), weather(2,true,63,66,58,1.0),
    weather(3,true,55,58,52,1.0), weather(4,true,52,57,48,2.3),
    weather(5,false,29,33,24,1.5), weather(6,true,61,70,57,1.7)]
contactSheet(tiles, 4, 6, 8, out)
print("wrote weather scenes to \(out) (clearDay clearNight partlyDay cloudy fog rain snowNight thunder)")
