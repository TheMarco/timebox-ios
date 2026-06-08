// Design sandbox for the Clock module's faces. Self-contained (no TimeboxKit). Renders all
// faces to one upscaled contact-sheet PNG so the look can be iterated WITHOUT the device.
//   swiftc -O tools/FacesPreview.swift -o /tmp/faces && /tmp/faces /tmp/faces.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Core types / helpers

struct PixelRGB: Equatable {
    var red: UInt8, green: UInt8, blue: UInt8
    init(red: UInt8, green: UInt8, blue: UInt8) { self.red = red; self.green = green; self.blue = blue }
    init(_ r: Int, _ g: Int, _ b: Int) { red = UInt8(max(0,min(255,r))); green = UInt8(max(0,min(255,g))); blue = UInt8(max(0,min(255,b))) }
}
struct Surface {
    let width: Int, height: Int
    var pixels: [PixelRGB]
    init(width: Int, height: Int, fill: PixelRGB = PixelRGB(red: 0, green: 0, blue: 0)) {
        self.width = width; self.height = height; pixels = Array(repeating: fill, count: width*height)
    }
    mutating func set(_ x: Int, _ y: Int, _ c: PixelRGB) { guard x>=0,x<width,y>=0,y<height else { return }; pixels[y*width+x]=c }
    func at(_ x: Int, _ y: Int) -> PixelRGB { pixels[y*width+x] }
}
func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v*255).rounded()))) }
func mix(_ a: PixelRGB, _ b: PixelRGB, _ t: Double) -> PixelRGB {
    func l(_ x: UInt8, _ y: UInt8) -> UInt8 { byte((Double(x)*(1-t)+Double(y)*t)/255) }
    return PixelRGB(red: l(a.red,b.red), green: l(a.green,b.green), blue: l(a.blue,b.blue))
}
func darken(_ c: PixelRGB, _ f: Double) -> PixelRGB { PixelRGB(red: byte(Double(c.red)/255*f), green: byte(Double(c.green)/255*f), blue: byte(Double(c.blue)/255*f)) }
func screenAdd(_ base: PixelRGB, _ c: PixelRGB, _ amt: Double) -> PixelRGB {
    func ch(_ b: UInt8,_ x: UInt8)->UInt8 { let bb=Double(b)/255, xx=min(1,Double(x)/255*amt); return byte(1-(1-bb)*(1-xx)) }
    return PixelRGB(red: ch(base.red,c.red), green: ch(base.green,c.green), blue: ch(base.blue,c.blue))
}
func hsv(_ h: Double, _ s: Double, _ v: Double) -> PixelRGB {
    let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
    let i = Int(hh), f = hh - Double(i)
    let p = v*(1-s), q = v*(1-s*f), t = v*(1-s*(1-f))
    let (r,g,b): (Double,Double,Double)
    switch i { case 0:(r,g,b)=(v,t,p); case 1:(r,g,b)=(q,v,p); case 2:(r,g,b)=(p,v,t); case 3:(r,g,b)=(p,q,v); case 4:(r,g,b)=(t,p,v); default:(r,g,b)=(v,p,q) }
    return PixelRGB(red: byte(r), green: byte(g), blue: byte(b))
}
let cal = Calendar(identifier: .gregorian)
func hms(_ d: Date) -> (Int,Int,Int) { let c=cal.dateComponents([.hour,.minute,.second],from:d); return (c.hour!,c.minute!,c.second!) }
func h12(_ h: Int) -> Int { let x = h % 12; return x==0 ? 12 : x }

// MARK: - Fonts

// 7-segment digit, pixel-perfect, in a w×h box at (ox,oy), thickness t.
let SEG: [[Bool]] = [ // a,b,c,d,e,f,g
 [true,true,true,true,true,true,false],[false,true,true,false,false,false,false],
 [true,true,false,true,true,false,true],[true,true,true,true,false,false,true],
 [false,true,true,false,false,true,true],[true,false,true,true,false,true,true],
 [true,false,true,true,true,true,true],[true,true,true,false,false,false,false],
 [true,true,true,true,true,true,true],[true,true,true,true,false,true,true]]
func seg7(_ s: inout Surface, _ ox: Int, _ oy: Int, _ w: Int, _ h: Int, _ t: Int, _ digit: Int, _ on: PixelRGB, ghost: PixelRGB? = nil) {
    let mx=ox+w-1, my=oy+h-1, mid=oy+h/2
    func bar(_ x0:Int,_ y0:Int,_ x1:Int,_ y1:Int,_ c:PixelRGB){ if x1<x0||y1<y0 {return}; for y in y0...y1 { for x in x0...x1 { s.set(x,y,c) } } }
    func drawSeg(_ i: Int, _ c: PixelRGB) {
        switch i {
        case 0: bar(ox+t, oy, mx-t, oy+t-1, c)             // a
        case 1: bar(mx-t+1, oy+t, mx, mid-1, c)            // b
        case 2: bar(mx-t+1, mid, mx, my-t, c)              // c
        case 3: bar(ox+t, my-t+1, mx-t, my, c)             // d
        case 4: bar(ox, mid, ox+t-1, my-t, c)              // e
        case 5: bar(ox, oy+t, ox+t-1, mid-1, c)            // f
        default: bar(ox+t, mid-t/2, mx-t, mid-t/2+t-1, c)  // g
        }
    }
    if let gh = ghost { for i in 0..<7 { drawSeg(i, gh) } }
    let d = SEG[digit]; for i in 0..<7 where d[i] { drawSeg(i, on) }
}
// Tiny 3×5 digit font (for scores/labels).
let D3: [[String]] = [
 ["###","#.#","#.#","#.#","###"],["..#","..#","..#","..#","..#"],["###","..#","###","#..","###"],
 ["###","..#","###","..#","###"],["#.#","#.#","###","..#","..#"],["###","#..","###","..#","###"],
 ["###","#..","###","#.#","###"],["###","..#","..#","..#","..#"],["###","#.#","###","#.#","###"],
 ["###","#.#","###","..#","###"]]
func d3(_ s: inout Surface, _ ox: Int, _ oy: Int, _ digit: Int, _ c: PixelRGB) {
    for (r,row) in D3[digit].enumerated() { for (i,ch) in row.enumerated() where ch=="#" { s.set(ox+i, oy+r, c) } }
}
// 5px uppercase font for the word clock (subset).
let LET: [Character:[String]] = [
 " ":[".....",".....",".....",".....","....."],
 "A":[".##.","#..#","####","#..#","#..#"],"C":[".###","#...","#...","#...",".###"],"E":["####","#...","###.","#...","####"],
 "F":["####","#...","###.","#...","#..."],"G":[".###","#...","#.##","#..#",".###"],"H":["#..#","#..#","####","#..#","#..#"],
 "I":["###",".#.",".#.",".#.","###"],"L":["#...","#...","#...","#...","####"],"N":["#..#","##.#","#.##","#..#","#..#"],
 "O":[".##.","#..#","#..#","#..#",".##."],"P":["###.","#..#","###.","#...","#..."],"Q":["####","#..#","#..#","####","..##"],
 "R":["###.","#..#","###.","#.#.","#..#"],"S":[".###","#...",".##.","...#","###."],"T":["#####","..#..","..#..","..#..","..#.."],
 "U":["#..#","#..#","#..#","#..#",".##."],"V":["#...#","#...#",".#.#.",".#.#.","..#.."],"W":["#...#","#...#","#.#.#","#.#.#",".#.#."],
 "X":["#..#","#..#",".##.","#..#","#..#"],"Y":["#..#","#..#",".##.","..#.","..#."],"'":["#","#",".",".","."]]
func letW(_ ch: Character) -> Int { (LET[ch]?.first?.count ?? 4) }
func text5(_ s: inout Surface, _ str: String, _ cx: Int, _ y: Int, _ c: PixelRGB) {
    let w = str.reduce(0){ $0 + letW($1) + 1 } - 1
    var x = cx - w/2
    for ch in str { if let g = LET[ch] ?? LET[" "] { for (r,row) in g.enumerated() { for (i,p) in row.enumerated() where p=="#" { s.set(x+i, y+r, c) } } }; x += letW(ch)+1 }
}

// MARK: - Faces (each 64×64)

func bg(_ c: PixelRGB = PixelRGB(2,3,6)) -> Surface { Surface(width:64,height:64,fill:c) }

// 1. LCD — big 7-seg HH:MM, dim ghost segments, blinking colon.
func faceLCD(_ d: Date) -> Surface {
    var s = bg(PixelRGB(3,6,5))
    let (h0,m,sec) = hms(d); let h = h12(h0)
    let on = PixelRGB(60,255,180), ghost = PixelRGB(10,40,30)
    let dw=12, dh=30, t=3, oy=17
    let digits=[h/10,h%10,m/10,m%10]; var x=3
    for (i,dg) in digits.enumerated() {
        if !(i==0 && dg==0) { seg7(&s,x,oy,dw,dh,t,dg,on,ghost:ghost) }
        x += dw+2
        if i==1 { if sec%2==0 { s.set(x,oy+dh/3,on); s.set(x+1,oy+dh/3,on); s.set(x,oy+2*dh/3,on); s.set(x+1,oy+2*dh/3,on) }; x+=4 }
    }
    return s
}

// 2. Analog — radial face, ticks, glowing hands.
func faceAnalog(_ d: Date) -> Surface {
    var s = bg(PixelRGB(6,7,14))
    let (h0,m,sec)=hms(d); let cx=32.0, cy=32.0
    let acc = PixelRGB(120,180,255)
    for r in 0..<32 { for a in 0..<256 {
        let th=Double(a)/256*2 * .pi; let x=Int(cx+Double(r)*sin(th)), y=Int(cy-Double(r)*cos(th))
        if r>30 { s.set(x,y, mix(PixelRGB(6,7,14), darken(acc,0.5), 0.5)) }
    }}
    func pt(_ turns: Double,_ rad: Double)->(Int,Int){ let th=turns*2 * .pi; return (Int(cx+rad*sin(th)),Int(cy-rad*cos(th))) }
    for i in 0..<60 { let (x,y)=pt(Double(i)/60, i%5==0 ? 27 : 29); s.set(x,y, i%5==0 ? PixelRGB(210,220,250):PixelRGB(80,90,120)) }
    func hand(_ turns:Double,_ len:Double,_ c:PixelRGB){ let (tx,ty)=pt(turns,len); var x=cx; var y=cy; let steps=Int(len*2); for k in 0...steps { let f=Double(k)/Double(steps); s.set(Int(x+(Double(tx)-x)*f),Int(y+(Double(ty)-y)*f),c) } }
    let mm=Double(m)+Double(sec)/60, hh=Double(h0%12)+mm/60
    hand(hh/12,15,PixelRGB(235,240,255)); hand(mm/60,23,acc); hand(Double(sec)/60,25,PixelRGB(255,80,70))
    s.set(32,32,PixelRGB(255,255,255))
    return s
}

// 3. Flip clock — two split-flap cards (HH, MM) with a seam.
func faceFlip(_ d: Date) -> Surface {
    var s = bg(PixelRGB(8,8,10))
    let (h0,m,_)=hms(d); let h=h12(h0)
    func card(_ ox:Int,_ a:Int,_ b:Int){
        for y in 12...51 { for x in ox...(ox+25) {
            let edge = (x==ox||x==ox+25||y==12||y==51)
            s.set(x,y, edge ? PixelRGB(40,40,48) : PixelRGB(24,24,30))
        }}
        for x in ox...(ox+25) { s.set(x,31, PixelRGB(6,6,8)); s.set(x,32, PixelRGB(48,48,58)) } // seam
        let cream=PixelRGB(240,236,220)
        seg7(&s,ox+3,18,9,26,2,a,cream); seg7(&s,ox+14,18,9,26,2,b,cream)
    }
    card(4,h/10,h%10); card(35,m/10,m%10)
    return s
}

// 4. Binary — BCD dot columns HH MM SS.
func faceBinary(_ d: Date) -> Surface {
    var s = bg(PixelRGB(2,4,3))
    let (h0,m,sec)=hms(d)
    let cols=[h0/10,h0%10,m/10,m%10,sec/10,sec%10]
    let on=PixelRGB(60,255,120), off=PixelRGB(14,32,20)
    for (ci,val) in cols.enumerated() {
        let cx = 7 + ci*9 + (ci/2)*3
        for bit in 0..<4 { let lit = (val>>(3-bit))&1==1
            let cy = 18 + bit*9
            for dy in -2...2 { for dx in -2...2 { if dx*dx+dy*dy<=4 { s.set(cx+dx,cy+dy, lit ? on:off) } } }
        }
    }
    return s
}

// 5. Word clock — minute phrase / PAST|TO / hour, centered.
let WORDS=["TWELVE","ONE","TWO","THREE","FOUR","FIVE","SIX","SEVEN","EIGHT","NINE","TEN","ELEVEN","TWELVE"]
let MINS=["O'CLOCK","FIVE","TEN","QUARTER","TWENTY","TWENTY FIVE","HALF"]
func faceWord(_ d: Date) -> Surface {
    var s = bg(PixelRGB(10,6,16))
    let (h0,m,_)=hms(d); let r=(m+2)/5*5
    let acc=PixelRGB(255,170,90)
    if r==0 || r==60 { let hr=h12(r==60 ? h0+1 : h0); text5(&s,WORDS[hr],32,18,acc); text5(&s,"O'CLOCK",32,30,acc) }
    else { let idx = r<=30 ? r/5 : (60-r)/5; let conn = r<=30 ? "PAST":"TO"; let hr=h12(r<=30 ? h0 : h0+1)
        text5(&s,MINS[idx],32,12,acc); text5(&s,conn,32,26,mix(acc,PixelRGB(255,255,255),0.3)); text5(&s,WORDS[hr],32,40,acc) }
    return s
}

// 6. Rainbow — big 7-seg HH:MM filled with a moving hue gradient.
func faceRainbow(_ d: Date) -> Surface {
    var s = bg(PixelRGB(0,0,0))
    let (h0,m,sec)=hms(d); let h=h12(h0)
    var mask = Surface(width:64,height:64)
    let white=PixelRGB(255,255,255); let dw=12,dh=30,t=4,oy=17
    let digits=[h/10,h%10,m/10,m%10]; var x=3
    for (i,dg) in digits.enumerated(){ if !(i==0&&dg==0){ seg7(&mask,x,oy,dw,dh,t,dg,white) }; x+=dw+2; if i==1 { mask.set(x,oy+dh/3,white);mask.set(x+1,oy+dh/3,white);mask.set(x,oy+2*dh/3,white);mask.set(x+1,oy+2*dh/3,white); x+=4 } }
    for y in 0..<64 { for x in 0..<64 where mask.at(x,y).red>0 {
        let hue = Double(x)/64 + Double(y)/128 + Double(sec)/20
        s.set(x,y, hsv(hue,0.9,1)) }}
    return s
}

// 7. Pong — net, paddles, ball, score = H | M.
func facePong(_ d: Date) -> Surface {
    var s = bg(PixelRGB(0,0,0))
    let (h0,m,sec)=hms(d); let h=h12(h0)
    let w=PixelRGB(235,235,235)
    for y in stride(from:2,to:64,by:4){ s.set(31,y,darken(w,0.4)); s.set(32,y,darken(w,0.4)) }
    d3(&s,18,4,h/10,w); d3(&s,22,4,h%10,w); d3(&s,38,4,m/10,w); d3(&s,42,4,m%10,w)
    let phase=Double(sec)/60; let bx = Int(6 + abs(sin(phase * .pi*2))*52); let by = Int(20 + abs(sin(phase * .pi*3))*38)
    for dy in 0...1 { for dx in 0...1 { s.set(bx+dx,by+dy,w) } }
    for y in (by-4)...(by+5){ s.set(3,y,w);s.set(4,y,w) }; for y in (by-3)...(by+6){ s.set(59,y,w);s.set(60,y,w) }
    return s
}

// 8. Neon — glowing 7-seg tubes.
func faceNeon(_ d: Date) -> Surface {
    var s = bg(PixelRGB(8,4,14))
    let (h0,m,sec)=hms(d); let h=h12(h0)
    var core = Surface(width:64,height:64)
    let tube=PixelRGB(255,40,160); let dw=12,dh=30,t=3,oy=17
    let digits=[h/10,h%10,m/10,m%10]; var x=3
    for (i,dg) in digits.enumerated(){ if !(i==0&&dg==0){ seg7(&core,x,oy,dw,dh,t,dg,tube) }; x+=dw+2; if i==1 { if sec%2==0 { core.set(x,oy+10,tube);core.set(x+1,oy+10,tube);core.set(x,oy+20,tube);core.set(x+1,oy+20,tube) }; x+=4 } }
    // glow: spread lit pixels
    for y in 0..<64 { for x in 0..<64 where core.at(x,y).red>0 || core.at(x,y).blue>0 {
        for dy in -2...2 { for dx in -2...2 { let dd=dx*dx+dy*dy; if dd<=4 { let f=0.5/(1+Double(dd)); s.set(x+dx,y+dy, screenAdd(s.at(x+dx,y+dy), tube, f)) } } } } }
    for y in 0..<64 { for x in 0..<64 where core.at(x,y).red>0 || core.at(x,y).blue>0 { s.set(x,y, mix(tube,PixelRGB(255,230,250),0.7)) } }
    return s
}

// 9. Matrix rain — green falling glyphs, time brighter in the middle.
func faceMatrix(_ d: Date) -> Surface {
    var s = bg(PixelRGB(0,4,0))
    let (h0,m,_)=hms(d); let h=h12(h0); let secf = Double(hms(d).2)
    for x in stride(from:0,to:64,by:3){
        let speed = 6.0 + Double((x*37)%11)
        let head = Int((secf*speed + Double((x*53)%64))) % 80 - 8
        for k in 0..<14 { let y=head-k; if y>=0 && y<64 { let g = 255 - k*16; s.set(x,y, k==0 ? PixelRGB(200,255,200):PixelRGB(0,max(40,g),0)) } }
    }
    // dim band + time
    for y in 24...39 { for x in 0..<64 { s.set(x,y, darken(s.at(x,y),0.25)) } }
    let on=PixelRGB(180,255,180),dw=9,dh=18,t=2,oy=23
    let digits=[h/10,h%10,m/10,m%10]; var x=10
    for (i,dg) in digits.enumerated(){ if !(i==0&&dg==0){ seg7(&s,x,oy,dw,dh,t,dg,on) }; x+=dw+2; if i==1 { s.set(x,oy+5,on);s.set(x,oy+12,on); x+=4 } }
    return s
}

// 10. Arc rings — concentric H/M/S progress arcs + center time.
func faceArcs(_ d: Date) -> Surface {
    var s = bg(PixelRGB(4,5,10))
    let (h0,m,sec)=hms(d); let cx=32.0,cy=32.0
    func ring(_ rad: Double,_ frac: Double,_ c: PixelRGB){
        let n=Int(rad*7)
        for i in 0...n { let f=Double(i)/Double(n); let th = -(.pi/2) + f*2 * .pi
            let x=Int(cx+rad*cos(th)), y=Int(cy+rad*sin(th))
            s.set(x,y, f<=frac ? c : darken(c,0.18)) }
    }
    ring(29, Double(sec)/60, PixelRGB(255,90,90))
    ring(24, (Double(m)+Double(sec)/60)/60, PixelRGB(80,220,255))
    ring(19, (Double(h0%12)+Double(m)/60)/12, PixelRGB(160,120,255))
    let on=PixelRGB(230,235,255),dw=6,dh=12,t=2,oy=26
    let h=h12(h0); let digits=[h/10,h%10,m/10,m%10]; var x=20
    for (i,dg) in digits.enumerated(){ if !(i==0&&dg==0){ seg7(&s,x,oy,dw,dh,t,dg,on) }; x+=dw+1; if i==1 { s.set(x,oy+3,on);s.set(x,oy+8,on); x+=3 } }
    return s
}

// 11. Color clock — fill with #HHMMSS (24h time as a hex color), hex shown as text.
func hexNibble2(_ v: Int) -> Int { (v/10)*16 + (v%10) }
let HASH3 = ["#.#","###","#.#","###","#.#"]
func faceColor(_ d: Date) -> Surface {
    let (h,m,sec) = hms(d)
    let col = PixelRGB(hexNibble2(h), hexNibble2(m), hexNibble2(sec))
    var s = Surface(width:64,height:64, fill: col)
    let lum = (0.299*Double(col.red)+0.587*Double(col.green)+0.114*Double(col.blue))/255
    let ink = lum > 0.5 ? PixelRGB(0,0,0) : PixelRGB(245,245,245)
    let glyphs = [HASH3] + [h/10,h%10,m/10,m%10,sec/10,sec%10].map { D3[$0] }
    let cw=6, gap=2; let total = glyphs.count*cw + (glyphs.count-1)*gap
    var x=(64-total)/2; let y=(64-10)/2
    for g in glyphs { for (r,row) in g.enumerated() { for (i,p) in row.enumerated() where p=="#" { for sy in 0..<2 { for sx in 0..<2 { s.set(x+i*2+sx, y+r*2+sy, ink) } } } }; x += cw+gap }
    return s
}

// MARK: - Contact sheet

func contactSheet(_ tiles: [Surface], cols: Int, scale: Int, gap: Int, to path: String) {
    let rows=(tiles.count+cols-1)/cols, tw=64*scale, th=64*scale
    let W = cols*tw + (cols+1)*gap, H = rows*th + (rows+1)*gap
    var buf=[UInt8](repeating: 30, count: W*H*4)
    for (idx,t) in tiles.enumerated() {
        let r=idx/cols, c=idx%cols, ox=gap+c*(tw+gap), oy=gap+r*(th+gap)
        for y in 0..<th { for x in 0..<tw { let sp=t.at(x/scale,y/scale); let o=((oy+y)*W+ox+x)*4; buf[o]=sp.red;buf[o+1]=sp.green;buf[o+2]=sp.blue;buf[o+3]=255 } }
    }
    let cs=CGColorSpaceCreateDeviceRGB()
    let ctx=CGContext(data:&buf,width:W,height:H,bitsPerComponent:8,bytesPerRow:W*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let img=ctx.makeImage()!
    let dest=CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL, UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(dest,img,nil); CGImageDestinationFinalize(dest)
}

// MARK: - main
let out = CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "/tmp/faces.png"
func date(_ h:Int,_ m:Int,_ s:Int)->Date{ var c=DateComponents(); c.year=2026;c.month=6;c.day=7;c.hour=h;c.minute=m;c.second=s; return cal.date(from:c)! }
let t = date(10,9,36)
let tiles=[faceLCD(t),faceAnalog(t),faceFlip(t),faceBinary(t),faceWord(t),faceRainbow(t),facePong(t),faceNeon(t),faceMatrix(t),faceArcs(t),faceColor(t)]
contactSheet(tiles, cols: 4, scale: 6, gap: 8, to: out)
print("wrote \(tiles.count) faces to \(out)  (order: LCD Analog Flip Binary Word Rainbow Pong Neon Matrix Arcs Color)")
