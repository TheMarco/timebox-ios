import SwiftUI
import CoreGraphics
import TimeboxKit

/// Clock module — ten 64×64 clock faces (digital, analog, flip, and a few weird ones). The
/// selected face is rendered live and streamed to the device; the picker shows a big live
/// preview plus a grid of tappable thumbnails. Faces are designed for the Pixoo's 64×64; a
/// 16×16 Timebox falls back to the rich analog.

// MARK: - Small helpers / fonts (file-private)

private extension PixelRGB {
    init(_ r: Int, _ g: Int, _ b: Int) {
        self.init(red: UInt8(max(0, min(255, r))), green: UInt8(max(0, min(255, g))), blue: UInt8(max(0, min(255, b))))
    }
}
private func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
private func hsv(_ h: Double, _ s: Double, _ v: Double) -> PixelRGB {
    let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
    let i = Int(hh), f = hh - Double(i)
    let p = v*(1-s), q = v*(1-s*f), t = v*(1-s*(1-f))
    let (r,g,b): (Double,Double,Double)
    switch i { case 0:(r,g,b)=(v,t,p); case 1:(r,g,b)=(q,v,p); case 2:(r,g,b)=(p,v,t); case 3:(r,g,b)=(p,q,v); case 4:(r,g,b)=(t,p,v); default:(r,g,b)=(v,p,q) }
    return PixelRGB(red: byte(r), green: byte(g), blue: byte(b))
}
private let faceCal = Calendar(identifier: .gregorian)
private func hms(_ d: Date) -> (Int, Int, Int) {
    let c = faceCal.dateComponents([.hour, .minute, .second], from: d); return (c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
}
private func h12(_ h: Int) -> Int { let x = h % 12; return x == 0 ? 12 : x }
private func bg(_ c: PixelRGB = PixelRGB(2, 3, 6)) -> Surface { Surface(width: 64, height: 64, fill: c) }

// 7-segment digit, pixel-perfect, in a w×h box at (ox,oy), thickness t.
private let SEG: [[Bool]] = [ // a,b,c,d,e,f,g
 [true,true,true,true,true,true,false],[false,true,true,false,false,false,false],
 [true,true,false,true,true,false,true],[true,true,true,true,false,false,true],
 [false,true,true,false,false,true,true],[true,false,true,true,false,true,true],
 [true,false,true,true,true,true,true],[true,true,true,false,false,false,false],
 [true,true,true,true,true,true,true],[true,true,true,true,false,true,true]]
private func seg7(_ s: inout Surface, _ ox: Int, _ oy: Int, _ w: Int, _ h: Int, _ t: Int, _ digit: Int, _ on: PixelRGB, ghost: PixelRGB? = nil) {
    let mx = ox+w-1, my = oy+h-1, mid = oy+h/2
    func bar(_ x0:Int,_ y0:Int,_ x1:Int,_ y1:Int,_ c:PixelRGB){ if x1<x0||y1<y0 {return}; for y in y0...y1 { for x in x0...x1 { s.set(x,y,c) } } }
    func drawSeg(_ i: Int, _ c: PixelRGB) {
        switch i {
        case 0: bar(ox+t, oy, mx-t, oy+t-1, c)
        case 1: bar(mx-t+1, oy+t, mx, mid-1, c)
        case 2: bar(mx-t+1, mid, mx, my-t, c)
        case 3: bar(ox+t, my-t+1, mx-t, my, c)
        case 4: bar(ox, mid, ox+t-1, my-t, c)
        case 5: bar(ox, oy+t, ox+t-1, mid-1, c)
        default: bar(ox+t, mid-t/2, mx-t, mid-t/2+t-1, c)
        }
    }
    if let gh = ghost { for i in 0..<7 { drawSeg(i, gh) } }
    let d = SEG[digit]; for i in 0..<7 where d[i] { drawSeg(i, on) }
}
// Tiny 3×5 digit font (scores).
private let D3: [[String]] = [
 ["###","#.#","#.#","#.#","###"],["..#","..#","..#","..#","..#"],["###","..#","###","#..","###"],
 ["###","..#","###","..#","###"],["#.#","#.#","###","..#","..#"],["###","#..","###","..#","###"],
 ["###","#..","###","#.#","###"],["###","..#","..#","..#","..#"],["###","#.#","###","#.#","###"],
 ["###","#.#","###","..#","###"]]
private func d3(_ s: inout Surface, _ ox: Int, _ oy: Int, _ digit: Int, _ c: PixelRGB) {
    for (r,row) in D3[digit].enumerated() { for (i,ch) in row.enumerated() where ch=="#" { s.set(ox+i, oy+r, c) } }
}
// 5px uppercase font for the word clock (subset).
private let LET: [Character:[String]] = [
 " ":[".....",".....",".....",".....","....."],
 "A":[".##.","#..#","####","#..#","#..#"],"C":[".###","#...","#...","#...",".###"],"E":["####","#...","###.","#...","####"],
 "F":["####","#...","###.","#...","#..."],"G":[".###","#...","#.##","#..#",".###"],"H":["#..#","#..#","####","#..#","#..#"],
 "I":["###",".#.",".#.",".#.","###"],"L":["#...","#...","#...","#...","####"],"N":["#..#","##.#","#.##","#..#","#..#"],
 "O":[".##.","#..#","#..#","#..#",".##."],"P":["###.","#..#","###.","#...","#..."],"Q":["####","#..#","#..#","####","..##"],
 "R":["###.","#..#","###.","#.#.","#..#"],"S":[".###","#...",".##.","...#","###."],"T":["#####","..#..","..#..","..#..","..#.."],
 "U":["#..#","#..#","#..#","#..#",".##."],"V":["#...#","#...#",".#.#.",".#.#.","..#.."],"W":["#...#","#...#","#.#.#","#.#.#",".#.#."],
 "M":["#...#","##.##","#.#.#","#...#","#...#"],
 "X":["#..#","#..#",".##.","#..#","#..#"],"Y":["#..#","#..#",".##.","..#.","..#."],"'":["#","#",".",".","."]]
private func letW(_ ch: Character) -> Int { LET[ch]?.first?.count ?? 4 }
private func text5(_ s: inout Surface, _ str: String, _ cx: Int, _ y: Int, _ c: PixelRGB) {
    let w = str.reduce(0) { $0 + letW($1) + 1 } - 1
    var x = cx - w/2
    for ch in str { if let g = LET[ch] ?? LET[" "] { for (r,row) in g.enumerated() { for (i,p) in row.enumerated() where p=="#" { s.set(x+i, y+r, c) } } }; x += letW(ch)+1 }
}

// MARK: - Faces (each 64×64)

private func faceLCD(_ d: Date) -> Surface {
    var s = bg(PixelRGB(3,6,5)); let (h0,m,sec) = hms(d); let h = h12(h0)
    let on = PixelRGB(60,255,180), ghost = PixelRGB(10,40,30); let dw=12,dh=30,t=3,oy=17
    let digits=[h/10,h%10,m/10,m%10]; var x=3
    for (i,dg) in digits.enumerated() {
        if !(i==0 && dg==0) { seg7(&s,x,oy,dw,dh,t,dg,on,ghost:ghost) }
        x += dw+2
        if i==1 { if sec%2==0 { s.set(x,oy+dh/3,on); s.set(x+1,oy+dh/3,on); s.set(x,oy+2*dh/3,on); s.set(x+1,oy+2*dh/3,on) }; x+=4 }
    }
    return s
}
private func faceFlip(_ d: Date) -> Surface {
    var s = bg(PixelRGB(8,8,10)); let (h0,m,_)=hms(d); let h=h12(h0)
    func card(_ ox:Int,_ a:Int,_ b:Int){
        for y in 12...51 { for x in ox...(ox+25) { let edge=(x==ox||x==ox+25||y==12||y==51); s.set(x,y, edge ? PixelRGB(40,40,48):PixelRGB(24,24,30)) } }
        for x in ox...(ox+25) { s.set(x,31,PixelRGB(6,6,8)); s.set(x,32,PixelRGB(48,48,58)) }
        let cream=PixelRGB(240,236,220); seg7(&s,ox+3,18,9,26,2,a,cream); seg7(&s,ox+14,18,9,26,2,b,cream)
    }
    card(4,h/10,h%10); card(35,m/10,m%10); return s
}
private func faceBinary(_ d: Date) -> Surface {
    var s = bg(PixelRGB(2,4,3)); let (h0,m,sec)=hms(d)
    let cols=[h0/10,h0%10,m/10,m%10,sec/10,sec%10]; let on=PixelRGB(60,255,120), off=PixelRGB(14,32,20)
    for (ci,val) in cols.enumerated() {
        let cx = 7 + ci*9 + (ci/2)*3
        for bit in 0..<4 { let lit=(val>>(3-bit))&1==1; let cy=18+bit*9
            for dy in -2...2 { for dx in -2...2 { if dx*dx+dy*dy<=4 { s.set(cx+dx,cy+dy, lit ? on:off) } } } }
    }
    return s
}
private let WORDS = ["TWELVE","ONE","TWO","THREE","FOUR","FIVE","SIX","SEVEN","EIGHT","NINE","TEN","ELEVEN","TWELVE"]
private let MINS = ["O'CLOCK","FIVE","TEN","QUARTER","TWENTY","TWENTY FIVE","HALF"]
private func faceWord(_ d: Date) -> Surface {
    var s = bg(PixelRGB(10,6,16)); let (h0,m,_)=hms(d); let r=(m+2)/5*5; let acc=PixelRGB(255,170,90)
    if r==0 || r==60 { let hr=h12(r==60 ? h0+1 : h0); text5(&s,WORDS[hr],32,18,acc); text5(&s,"O'CLOCK",32,30,acc) }
    else {
        let idx = r<=30 ? r/5 : (60-r)/5; let conn = r<=30 ? "PAST" : "TO"; let hr = h12(r<=30 ? h0 : h0+1)
        text5(&s,MINS[idx],32,12,acc); text5(&s,conn,32,26,Palette.mix(acc,PixelRGB(255,255,255),0.3)); text5(&s,WORDS[hr],32,40,acc)
    }
    return s
}
private func faceRainbow(_ d: Date) -> Surface {
    var s = bg(PixelRGB(0,0,0)); let (h0,m,sec)=hms(d); let h=h12(h0)
    var mask = Surface(width:64,height:64); let white=PixelRGB(255,255,255); let dw=12,dh=30,t=4,oy=17
    let digits=[h/10,h%10,m/10,m%10]; var x=3
    for (i,dg) in digits.enumerated(){ if !(i==0&&dg==0){ seg7(&mask,x,oy,dw,dh,t,dg,white) }; x+=dw+2; if i==1 { mask.set(x,oy+dh/3,white);mask.set(x+1,oy+dh/3,white);mask.set(x,oy+2*dh/3,white);mask.set(x+1,oy+2*dh/3,white); x+=4 } }
    for y in 0..<64 { for x in 0..<64 where mask.at(x,y).red>0 { s.set(x,y, hsv(Double(x)/64 + Double(y)/128 + Double(sec)/20, 0.9, 1)) } }
    return s
}
private func facePong(_ d: Date) -> Surface {
    var s = bg(PixelRGB(0,0,0)); let (h0,m,sec)=hms(d); let h=h12(h0); let w=PixelRGB(235,235,235)
    for y in stride(from:2,to:64,by:4){ s.set(31,y,Palette.darken(w,0.4)); s.set(32,y,Palette.darken(w,0.4)) }
    d3(&s,18,4,h/10,w); d3(&s,22,4,h%10,w); d3(&s,38,4,m/10,w); d3(&s,42,4,m%10,w)
    let phase=Double(sec)/60; let bx=Int(6 + abs(sin(phase * .pi*2))*52); let by=Int(20 + abs(sin(phase * .pi*3))*38)
    for dy in 0...1 { for dx in 0...1 { s.set(bx+dx,by+dy,w) } }
    for y in (by-4)...(by+5){ s.set(3,y,w);s.set(4,y,w) }; for y in (by-3)...(by+6){ s.set(59,y,w);s.set(60,y,w) }
    return s
}
private func faceNeon(_ d: Date) -> Surface {
    var s = bg(PixelRGB(8,4,14)); let (h0,m,sec)=hms(d); let h=h12(h0)
    var core = Surface(width:64,height:64); let tube=PixelRGB(255,40,160); let dw=12,dh=30,t=3,oy=17
    let digits=[h/10,h%10,m/10,m%10]; var x=3
    for (i,dg) in digits.enumerated(){ if !(i==0&&dg==0){ seg7(&core,x,oy,dw,dh,t,dg,tube) }; x+=dw+2; if i==1 { if sec%2==0 { core.set(x,oy+10,tube);core.set(x+1,oy+10,tube);core.set(x,oy+20,tube);core.set(x+1,oy+20,tube) }; x+=4 } }
    for y in 0..<64 { for x in 0..<64 where core.at(x,y).red>0 || core.at(x,y).blue>0 {
        for dy in -2...2 { for dx in -2...2 { let dd=dx*dx+dy*dy; if dd<=4 { s.set(x+dx,y+dy, Palette.screenAdd(s.at(x+dx,y+dy), tube, 0.5/(1+Double(dd)))) } } } } }
    for y in 0..<64 { for x in 0..<64 where core.at(x,y).red>0 || core.at(x,y).blue>0 { s.set(x,y, Palette.mix(tube,PixelRGB(255,230,250),0.7)) } }
    return s
}
private func faceMatrix(_ d: Date) -> Surface {
    var s = bg(PixelRGB(0,4,0)); let (h0,m,sec)=hms(d); let h=h12(h0); let secf=Double(sec)
    for x in stride(from:0,to:64,by:3){
        let speed = 6.0 + Double((x*37)%11); let head = Int(secf*speed + Double((x*53)%64)) % 80 - 8
        for k in 0..<14 { let y=head-k; if y>=0 && y<64 { let g=255-k*16; s.set(x,y, k==0 ? PixelRGB(200,255,200):PixelRGB(0,max(40,g),0)) } }
    }
    for y in 24...39 { for x in 0..<64 { s.set(x,y, Palette.darken(s.at(x,y),0.25)) } }
    let on=PixelRGB(180,255,180),dw=9,dh=18,t=2,oy=23; let digits=[h/10,h%10,m/10,m%10]; var x=10
    for (i,dg) in digits.enumerated(){ if !(i==0&&dg==0){ seg7(&s,x,oy,dw,dh,t,dg,on) }; x+=dw+2; if i==1 { s.set(x,oy+5,on);s.set(x,oy+12,on); x+=4 } }
    return s
}
private func faceArcs(_ d: Date) -> Surface {
    var s = bg(PixelRGB(4,5,10)); let (h0,m,sec)=hms(d); let cx=32.0, cy=32.0
    func ring(_ rad: Double,_ frac: Double,_ c: PixelRGB){
        let n=Int(rad*7)
        for i in 0...n { let f=Double(i)/Double(n); let th = -(Double.pi/2) + f*2*Double.pi
            s.set(Int(cx+rad*cos(th)), Int(cy+rad*sin(th)), f<=frac ? c : Palette.darken(c,0.18)) }
    }
    ring(29, Double(sec)/60, PixelRGB(255,90,90))
    ring(24, (Double(m)+Double(sec)/60)/60, PixelRGB(80,220,255))
    ring(19, (Double(h0%12)+Double(m)/60)/12, PixelRGB(160,120,255))
    let on=PixelRGB(230,235,255),dw=6,dh=12,t=2,oy=26; let h=h12(h0); let digits=[h/10,h%10,m/10,m%10]; var x=20
    for (i,dg) in digits.enumerated(){ if !(i==0&&dg==0){ seg7(&s,x,oy,dw,dh,t,dg,on) }; x+=dw+1; if i==1 { s.set(x,oy+3,on);s.set(x,oy+8,on); x+=3 } }
    return s
}

// 11. Hex clock — fill with #HHMMSS (24h time as a hex color), the hex shown as text.
private func hexNibble2(_ v: Int) -> Int { (v/10)*16 + (v%10) }
private let HASH3 = ["#.#","###","#.#","###","#.#"]
private func faceHex(_ d: Date) -> Surface {
    let (h,m,sec) = hms(d)
    let col = PixelRGB(hexNibble2(h), hexNibble2(m), hexNibble2(sec))
    var s = Surface(width: 64, height: 64, fill: col)
    let lum = (0.299*Double(col.red) + 0.587*Double(col.green) + 0.114*Double(col.blue)) / 255
    let ink = lum > 0.5 ? PixelRGB(0,0,0) : PixelRGB(245,245,245)
    let glyphs = [HASH3] + [h/10,h%10,m/10,m%10,sec/10,sec%10].map { D3[$0] }
    let cw=6, gap=2; let total = glyphs.count*cw + (glyphs.count-1)*gap
    var x=(64-total)/2; let y=(64-10)/2
    for g in glyphs { for (r,row) in g.enumerated() { for (i,p) in row.enumerated() where p=="#" { for sy in 0..<2 { for sx in 0..<2 { s.set(x+i*2+sx, y+r*2+sy, ink) } } } }; x += cw+gap }
    return s
}

// 12. Color clock — the real "1991 Color Clock": 4 wedges whose colors advance one per hour
// (pieceOrder [3,0,1,2]); the active wedge sweeps its next color with the minutes; a white dot
// orbits the ring with the seconds; AM/PM in the carved center. (mask.png overlay omitted.)
private func faceColorClock(_ d: Date) -> Surface {
    let (h0,m,sec) = hms(d)
    let ss = 4, big = 64*ss                                  // 4× supersample, box-averaged → smooth edges
    let cx = Double(big)/2, cy = Double(big)/2
    let radius = 26.0*Double(ss), hole = radius*0.24, ringMid = radius+3.0*Double(ss), ringHalf = 1.5*Double(ss)
    let colors = [PixelRGB(255,59,48), PixelRGB(255,149,0), PixelRGB(255,204,0)]  // red, orange, yellow (12h)
    let pieceOrder = [3,0,1,2]; let H = h0 % 12
    var seg = [0,0,0,0]; for t in 0..<H { let p = pieceOrder[t%4]; seg[p] = (seg[p]+1) % colors.count }
    let curPiece = pieceOrder[H%4], progress = Double(m)/60.0, wedge = Double.pi/3, twoPi = Double.pi*2
    let secAng = twoPi*Double(sec)/60 - Double.pi/2
    let sdx = cx+ringMid*cos(secAng), sdy = cy+ringMid*sin(secAng), sdr = 1.4*Double(ss)
    var acc = [Double](repeating: 0, count: 64*64*3)
    for by in 0..<big { for bx in 0..<big {
        let dxp = Double(bx)+0.5-cx, dyp = Double(by)+0.5-cy, dist = (dxp*dxp+dyp*dyp).squareRoot()
        var c: PixelRGB? = nil
        let ddx = Double(bx)+0.5-sdx, ddy = Double(by)+0.5-sdy
        if ddx*ddx+ddy*ddy <= sdr*sdr { c = PixelRGB(255,255,255) }
        else if dist <= hole { c = nil }
        else if abs(dist-ringMid) <= ringHalf { c = PixelRGB(85,85,85) }
        else if dist <= radius {
            let ang = atan2(dyp,dxp)
            for i in 0..<4 {
                let startA = Double(i)*Double.pi/2 - wedge/2
                var rel = (ang-startA).truncatingRemainder(dividingBy: twoPi); if rel < 0 { rel += twoPi }
                if rel <= wedge { let base = colors[seg[i] % colors.count]
                    c = (i==curPiece && rel <= wedge*progress) ? colors[(seg[i]+1) % colors.count] : base; break }
            }
        }
        if let c = c { let o = ((by/ss)*64+(bx/ss))*3; acc[o] += Double(c.red); acc[o+1] += Double(c.green); acc[o+2] += Double(c.blue) }
    }}
    let inv = 1.0/Double(ss*ss); var px = [PixelRGB](); px.reserveCapacity(64*64)
    for o in stride(from: 0, to: 64*64*3, by: 3) { px.append(PixelRGB(Int((acc[o]*inv).rounded()), Int((acc[o+1]*inv).rounded()), Int((acc[o+2]*inv).rounded()))) }
    var s = Surface(width: 64, height: 64); s.pixels = px
    text5(&s, h0 < 12 ? "AM" : "PM", 32, 29, PixelRGB(235,235,235))
    return s
}

// MARK: - Face catalog

enum ClockFace: String, CaseIterable, Identifiable {
    case lcd, analog, flip, binary, word, rainbow, pong, neon, matrix, arcs, hex, color
    var id: String { rawValue }
    var name: String {
        switch self {
        case .lcd: return "LCD";       case .analog: return "Analog"; case .flip: return "Flip"
        case .binary: return "Binary"; case .word: return "Words";    case .rainbow: return "Rainbow"
        case .pong: return "Pong";     case .neon: return "Neon";     case .matrix: return "Matrix"
        case .arcs: return "Rings";    case .hex: return "Hex";       case .color: return "Color"
        }
    }
    /// Render at the device size. Faces are built for 64×64; smaller panels get the rich analog.
    func render(size: Int, date: Date) -> Surface {
        guard size == 64 else { return ClockRenderer.surface(for: date, size: size) }
        switch self {
        case .lcd: return faceLCD(date)
        case .analog: return ClockRenderer.surface(for: date, size: size)
        case .flip: return faceFlip(date)
        case .binary: return faceBinary(date)
        case .word: return faceWord(date)
        case .rainbow: return faceRainbow(date)
        case .pong: return facePong(date)
        case .neon: return faceNeon(date)
        case .matrix: return faceMatrix(date)
        case .arcs: return faceArcs(date)
        case .hex: return faceHex(date)
        case .color: return faceColorClock(date)
        }
    }
}

// MARK: - Driver (streams the selected face to the device)

@MainActor
final class ClockDriver: ObservableObject {
    @Published var face: ClockFace { didSet { UserDefaults.standard.set(face.rawValue, forKey: key) } }
    private let connection: TimeboxConnection
    private var loop: Task<Void, Never>?
    private let key = "clock.face"

    init(connection: TimeboxConnection) {
        self.connection = connection
        face = ClockFace(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .lcd
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await self?.connection.setBrightness(100)
            while let self, !Task.isCancelled {
                if self.connection.isConnected {
                    try? await self.connection.send(self.face.render(size: self.connection.profile.width, date: Date()))
                } else {
                    await self.connection.attemptReconnect()
                }
                try? await Task.sleep(nanoseconds: 250_000_000)   // ~3–4 fps; enough for the animated faces
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }
}

// MARK: - View

struct ClockFacesView: View {
    @EnvironmentObject private var connection: TimeboxConnection
    @StateObject private var driver: ClockDriver
    private let sample = faceCal.date(from: DateComponents(year: 2026, month: 6, day: 7, hour: 10, minute: 9, second: 36))!
    private let cols = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    init(connection: TimeboxConnection) { _driver = StateObject(wrappedValue: ClockDriver(connection: connection)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TimelineView(.periodic(from: Date(), by: 0.25)) { ctx in
                    faceImage(driver.face.render(size: 64, date: ctx.date))
                        .resizable().interpolation(.none).aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12)))
                }
                .padding(.top, 8)

                Text(connection.isConnected ? "Showing \(driver.face.name) on \(connection.profile.width)×\(connection.profile.height)" : "Not connected")
                    .font(.caption).foregroundStyle(.secondary)

                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(ClockFace.allCases) { f in
                        Button { driver.face = f } label: {
                            VStack(spacing: 4) {
                                faceImage(f.render(size: 64, date: sample))
                                    .resizable().interpolation(.none).aspectRatio(1, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(f.name).font(.caption2)
                                    .foregroundStyle(driver.face == f ? Color.accentColor : .secondary)
                            }
                            .padding(6)
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .stroke(driver.face == f ? Color.accentColor : .gray.opacity(0.25),
                                        lineWidth: driver.face == f ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Clock")
        .onAppear { driver.start() }
        .onDisappear { driver.stop() }
    }
}

// MARK: - Surface → SwiftUI Image

private func faceImage(_ s: Surface) -> Image {
    let w = s.width, h = s.height
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for i in 0..<s.pixels.count { let p = s.pixels[i]; bytes[i*4]=p.red; bytes[i*4+1]=p.green; bytes[i*4+2]=p.blue; bytes[i*4+3]=255 }
    let cs = CGColorSpaceCreateDeviceRGB()
    if let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                           space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
       let cg = ctx.makeImage() {
        return Image(decorative: cg, scale: 1)
    }
    return Image(systemName: "clock")
}
