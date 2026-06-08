import SwiftUI
import CoreGraphics
import CoreLocation
import WeatherKit
import TimeboxKit

/// Weather module — pulls current conditions from Apple WeatherKit for the iPhone's location
/// and streams a stunning animated 64×64 scene (gradient sky, sun/moon/clouds/rain/snow/storm,
/// big temperature, hi/lo) to the device. Units are user-configurable (°F/°C).

// MARK: - Renderer (supersampled, anti-aliased)

private struct RGBf { var r=0.0, g=0.0, b=0.0; init(_ r:Double,_ g:Double,_ b:Double){self.r=r;self.g=g;self.b=b}
    init(_ r:Int,_ g:Int,_ b:Int){ self.r=Double(r)/255; self.g=Double(g)/255; self.b=Double(b)/255 } }
private func fmix(_ a:RGBf,_ b:RGBf,_ t:Double)->RGBf{ let t=max(0,min(1,t)); return RGBf(a.r+(b.r-a.r)*t,a.g+(b.g-a.g)*t,a.b+(b.b-a.b)*t) }
private func fscreen(_ a:RGBf,_ b:RGBf,_ amt:Double)->RGBf{ let m=max(0,min(1,amt)); return RGBf(1-(1-a.r)*(1-b.r*m),1-(1-a.g)*(1-b.g*m),1-(1-a.b)*(1-b.b*m)) }

private final class WCanvas {
    let W:Int; var px:[RGBf]
    init(_ w:Int,_ fill:RGBf){ W=w; px=Array(repeating:fill,count:w*w) }
    func at(_ x:Int,_ y:Int)->RGBf{ px[y*W+x] }
    func over(_ x:Int,_ y:Int,_ c:RGBf,_ a:Double){ if x>=0,x<W,y>=0,y<W { px[y*W+x]=fmix(px[y*W+x],c,a) } }
    func screen(_ x:Int,_ y:Int,_ c:RGBf,_ a:Double){ if x>=0,x<W,y>=0,y<W { px[y*W+x]=fscreen(px[y*W+x],c,a) } }
}
private func disc(_ cv:WCanvas,_ cx:Double,_ cy:Double,_ r:Double,_ c:RGBf,_ a:Double=1){
    let x0=Int(cx-r-1),x1=Int(cx+r+1),y0=Int(cy-r-1),y1=Int(cy+r+1)
    for y in y0...y1 { for x in x0...x1 {
        let dist=((Double(x)+0.5-cx)*(Double(x)+0.5-cx)+(Double(y)+0.5-cy)*(Double(y)+0.5-cy)).squareRoot()
        let cov=max(0,min(1,r-dist+0.5)); if cov>0 { cv.over(x,y,c,a*cov) } }}
}
private func glow(_ cv:WCanvas,_ cx:Double,_ cy:Double,_ r:Double,_ c:RGBf,_ s:Double){
    let x0=Int(cx-r),x1=Int(cx+r),y0=Int(cy-r),y1=Int(cy+r)
    for y in y0...y1 { for x in x0...x1 {
        let dist=((Double(x)+0.5-cx)*(Double(x)+0.5-cx)+(Double(y)+0.5-cy)*(Double(y)+0.5-cy)).squareRoot()
        if dist<r { cv.screen(x,y,c,s*pow(1-dist/r,2.2)) } }}
}
private func line(_ cv:WCanvas,_ x0:Double,_ y0:Double,_ x1:Double,_ y1:Double,_ w:Double,_ c:RGBf,_ a:Double=1){
    let steps=Int(max(abs(x1-x0),abs(y1-y0)))+1
    for i in 0...steps { let t=Double(i)/Double(steps); disc(cv,x0+(x1-x0)*t,y0+(y1-y0)*t,w/2,c,a) }
}
private func cloud(_ cv:WCanvas,_ cx:Double,_ cy:Double,_ sc:Double,_ top:RGBf,_ bot:RGBf){
    let lobes:[(Double,Double,Double)]=[(-2.2,0.2,1.0),(-0.9,-0.7,1.35),(0.7,-0.8,1.25),(2.1,0.1,1.0),(0.2,0.4,1.5)]
    for (dx,dy,r) in lobes { disc(cv,cx+dx*sc,cy+dy*sc,r*sc,bot) }
    for (dx,dy,r) in lobes { disc(cv,cx+dx*sc,cy-0.45*sc+dy*sc,r*sc*0.92,top) }
}

private let DIG:[[String]]=[
 [".###.","#...#","#...#","#...#","#...#","#...#",".###."],["..#..",".##..","..#..","..#..","..#..","..#..",".###."],
 [".###.","#...#","....#","...#.","..#..",".#...","#####"],["####.","....#","....#",".###.","....#","....#","####."],
 ["...#.","..##.",".#.#.","#..#.","#####","...#.","...#."],["#####","#....","####.","....#","....#","#...#",".###."],
 [".###.","#....","#....","####.","#...#","#...#",".###."],["#####","....#","...#.","..#..",".#...",".#...",".#..."],
 [".###.","#...#","#...#",".###.","#...#","#...#",".###."],[".###.","#...#","#...#",".####","....#","....#",".###."]]
private let SM:[[String]]=[
 ["###","#.#","#.#","#.#","###"],["..#","..#","..#","..#","..#"],["###","..#","###","#..","###"],["###","..#","###","..#","###"],
 ["#.#","#.#","###","..#","..#"],["###","#..","###","..#","###"],["###","#..","###","#.#","###"],["###","..#","..#","..#","..#"],
 ["###","#.#","###","#.#","###"],["###","#.#","###","..#","###"]]

enum WeatherRenderer {
    private static func skyColors(_ cond:Int,_ day:Bool)->(RGBf,RGBf){
        switch cond {
        case 0: return day ? (RGBf(36,110,214),RGBf(150,205,250)) : (RGBf(8,10,34),RGBf(30,38,86))
        case 1: return day ? (RGBf(54,120,200),RGBf(168,200,236)) : (RGBf(12,14,38),RGBf(40,48,90))
        case 2: return (RGBf(92,104,126),RGBf(150,160,180))
        case 3: return (RGBf(120,126,138),RGBf(168,172,182))
        case 4: return (RGBf(48,60,86),RGBf(96,108,134))
        case 5: return (RGBf(120,132,158),RGBf(178,190,212))
        default: return (RGBf(22,22,40),RGBf(58,58,86))
        }
    }
    /// 64×64 weather scene. `cond`: 0 clear,1 partly,2 cloudy,3 fog,4 rain,5 snow,6 thunder.
    static func surface(cond:Int, isDay day:Bool, temp:Int, hi:Int, lo:Int, phase:Double) -> Surface {
        let ss=4, W=64*ss
        let (top,bot)=skyColors(cond,day)
        let cv=WCanvas(W,top)
        for y in 0..<W { let c=fmix(top,bot,pow(Double(y)/Double(W-1),0.9)); for x in 0..<W { cv.px[y*W+x]=c } }
        func P(_ v:Double)->Double{ v*Double(ss) }
        let icx=P(32), icy=P(20)
        func sun(_ cx:Double,_ cy:Double,_ r:Double){
            glow(cv,cx,cy,r*3.2,RGBf(255,236,150),0.9)
            for k in 0..<12 { let ang=phase*0.4+Double(k)*Double.pi/6
                line(cv,cx+cos(ang)*r*1.5,cy+sin(ang)*r*1.5,cx+cos(ang)*r*2.1,cy+sin(ang)*r*2.1,P(1.4),RGBf(255,224,120),0.9) }
            disc(cv,cx,cy,r*1.12,RGBf(255,210,90)); disc(cv,cx,cy,r,RGBf(255,238,170))
        }
        func moon(_ cx:Double,_ cy:Double,_ r:Double){
            glow(cv,cx,cy,r*2.4,RGBf(180,200,255),0.5)
            disc(cv,cx,cy,r,RGBf(235,240,255)); disc(cv,cx+r*0.55,cy-r*0.35,r*0.92,fmix(top,bot,0.3))
        }
        func stars(){ for k in 0..<26 { let sx=Double((k*53)%64), sy=Double((k*29)%34)
            disc(cv,P(sx),P(sy),P(0.5),RGBf(255,255,255),0.5*(0.5+0.5*sin(phase*2+Double(k)))) } }
        func rain(_ n:Int,_ col:RGBf){ for k in 0..<n {
            let bx=Double((k*37)%64), off=(phase*40+Double((k*53)%64)).truncatingRemainder(dividingBy:64), y=18+off*0.7
            line(cv,P(bx),P(y),P(bx-2),P(y+6),P(0.8),col,0.75) } }
        func snow(_ n:Int){ for k in 0..<n {
            let bx=Double((k*41)%64), off=(phase*16+Double((k*59)%48)).truncatingRemainder(dividingBy:48)
            disc(cv,P(bx+2*sin(phase+Double(k))),P(20+off),P(1.0),RGBf(245,250,255),0.9) } }
        func bolt(){ let flash=max(0,sin(phase*3))>0.9 ? 0.5 : 0.0
            if flash>0 { for i in 0..<cv.px.count { cv.px[i]=fscreen(cv.px[i],RGBf(200,210,255),flash) } }
            var x=P(34), y=P(22); for (dx,dy) in [(P(-5),P(7)),(P(4),P(6)),(P(-4),P(7)),(P(3),P(6))] {
                line(cv,x,y,x+dx,y+dy,P(1.2),RGBf(255,240,150),0.95); x+=dx; y+=dy } }
        func fog(){ for b in 0..<5 { let y=P(Double(14+b*8))+sin(phase*0.6+Double(b))*P(6)
            for x in 0..<W { let a=0.18+0.10*sin(Double(x)/Double(W)*6+phase+Double(b))
                cv.over(x,Int(y),RGBf(235,238,245),a); cv.over(x,Int(y)+1,RGBf(235,238,245),a*0.7) } } }
        switch cond {
        case 0: if day { sun(icx,icy,P(9)) } else { stars(); moon(icx,icy,P(8)) }
        case 1: if day { sun(P(22),P(16),P(7)) } else { stars(); moon(P(22),P(15),P(6)) }; cloud(cv,P(38),P(24),P(3.4),RGBf(245,248,255),RGBf(180,190,210))
        case 2: cloud(cv,P(22),P(18),P(3.0),RGBf(210,216,230),RGBf(150,158,178)); cloud(cv,P(40),P(26),P(4.0),RGBf(235,240,250),RGBf(170,178,196))
        case 3: cloud(cv,P(32),P(14),P(3.4),RGBf(215,220,228),RGBf(170,176,186)); fog()
        case 4: cloud(cv,P(32),P(16),P(4.2),RGBf(180,190,210),RGBf(120,130,154)); rain(34,RGBf(160,200,255))
        case 5: cloud(cv,P(32),P(16),P(4.2),RGBf(220,228,244),RGBf(160,172,196)); snow(26)
        default: cloud(cv,P(32),P(16),P(4.4),RGBf(120,124,150),RGBf(70,74,100)); rain(24,RGBf(150,170,220)); bolt()
        }
        // downsample to a 64×64 Surface
        var s=Surface(width:64,height:64); let inv=1.0/Double(ss*ss)
        for oy in 0..<64 { for ox in 0..<64 {
            var r=0.0,g=0.0,b=0.0
            for dy in 0..<ss { for dx in 0..<ss { let p=cv.at(ox*ss+dx,oy*ss+dy); r+=p.r; g+=p.g; b+=p.b } }
            s.set(ox,oy,PixelRGB(red:byte(r*inv),green:byte(g*inv),blue:byte(b*inv)))
        }}
        drawTemp(&s,temp,46,PixelRGB(red:255,green:255,blue:255))
        smallNum(&s,hi,16,56,PixelRGB(red:255,green:180,blue:120)); smallNum(&s,lo,40,56,PixelRGB(red:150,green:190,blue:255))
        return s
    }
    private static func byte(_ v:Double)->UInt8{ UInt8(max(0,min(255,(v*255).rounded()))) }
    private static func bigDigit(_ s:inout Surface,_ d:Int,_ ox:Int,_ oy:Int,_ sc:Int,_ c:PixelRGB){
        for (r,row) in DIG[d].enumerated(){ for (i,ch) in row.enumerated() where ch=="#" {
            for sy in 0..<sc { for sx in 0..<sc { let x=ox+i*sc+sx, y=oy+r*sc+sy
                s.set(x+1,y+1,Palette.darken(s.at(min(63,x+1),min(63,y+1)),0.45)); s.set(x,y,c) } } } }
    }
    private static func drawTemp(_ s:inout Surface,_ v:Int,_ cyc:Int,_ c:PixelRGB){
        let sc=2, str=String(v), dw=5*sc, gap=sc, degW=4*sc
        let total=str.count*(dw+gap)-gap+sc+degW
        var x=(64-total)/2; let y=cyc-(7*sc)/2
        for ch in str { bigDigit(&s,Int(String(ch))!,x,y,sc,c); x+=dw+gap }
        x+=sc
        for yy in 0..<degW { for xx in 0..<degW { let dx=Double(xx)-Double(degW)/2+0.5, dy=Double(yy)-Double(degW)/2+0.5
            let d=(dx*dx+dy*dy).squareRoot(); if d<Double(degW)/2 && d>Double(degW)/2-1.6 { s.set(x+xx,y+yy,c) } } }
    }
    private static func smallNum(_ s:inout Surface,_ v:Int,_ ox:Int,_ oy:Int,_ c:PixelRGB){
        var x=ox; for ch in String(v) { let d=Int(String(ch))!
            for (r,row) in SM[d].enumerated(){ for (i,p) in row.enumerated() where p=="#" { s.set(x+i,oy+r,c) } }; x+=4 }
    }
}

private func condCode(_ c: WeatherCondition) -> Int {
    switch c {
    case .clear, .mostlyClear, .hot: return 0
    case .partlyCloudy, .breezy, .windy: return 1
    case .mostlyCloudy, .cloudy: return 2
    case .foggy, .haze, .smoky, .blowingDust: return 3
    case .drizzle, .rain, .heavyRain, .sunShowers, .freezingDrizzle, .freezingRain, .hail, .tropicalStorm, .hurricane: return 4
    case .flurries, .snow, .heavySnow, .blizzard, .blowingSnow, .sleet, .wintryMix, .sunFlurries, .frigid: return 5
    case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms: return 6
    @unknown default: return 2
    }
}

// MARK: - Location

final class LocationManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onLocation: ((CLLocation) -> Void)?
    var onStatus: ((String) -> Void)?
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }
    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        case .denied, .restricted: onStatus?("Location denied — enable it in Settings ▸ Privacy ▸ Location")
        @unknown default: break
        }
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .denied, .restricted: onStatus?("Location denied — enable it in Settings ▸ Privacy ▸ Location")
        default: break
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) { if let l = locs.last { onLocation?(l) } }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { onStatus?("Location error: \(error.localizedDescription)") }
}

// MARK: - Engine

@MainActor
final class WeatherEngine: ObservableObject {
    @Published var status = "Starting…"
    @Published var conditionText = ""
    @Published var city = ""
    @Published private(set) var hasData = false
    @Published var useCelsius: Bool { didSet { UserDefaults.standard.set(useCelsius, forKey: "wx.celsius") } }

    private var cond = 0, isDay = true
    private var tempC = 0.0, hiC = 0.0, loC = 0.0
    private let connection: TimeboxConnection
    private let locator = LocationManager()
    private var loop: Task<Void, Never>?
    private var lastLocation: CLLocation?
    private var lastFetch = Date.distantPast

    init(connection: TimeboxConnection) {
        self.connection = connection
        useCelsius = UserDefaults.standard.bool(forKey: "wx.celsius")
    }

    func start() {
        guard loop == nil else { return }
        locator.onStatus = { [weak self] t in Task { @MainActor in self?.status = t } }
        locator.onLocation = { [weak self] l in Task { @MainActor in await self?.gotLocation(l) } }
        status = "Locating…"
        locator.start()
        loop = Task { [weak self] in await self?.renderLoop() }
    }
    func stop() { loop?.cancel(); loop = nil }

    private func gotLocation(_ l: CLLocation) async {
        lastLocation = l
        CLGeocoder().reverseGeocodeLocation(l) { [weak self] places, _ in
            if let c = places?.first?.locality { Task { @MainActor in self?.city = c } }
        }
        await fetch(l)
    }

    private func fetch(_ l: CLLocation) async {
        do {
            let w = try await WeatherService.shared.weather(for: l)
            cond = condCode(w.currentWeather.condition)
            isDay = w.currentWeather.isDaylight
            tempC = w.currentWeather.temperature.converted(to: .celsius).value
            if let today = w.dailyForecast.first {
                hiC = today.highTemperature.converted(to: .celsius).value
                loC = today.lowTemperature.converted(to: .celsius).value
            }
            conditionText = w.currentWeather.condition.description
            hasData = true
            lastFetch = Date()
            status = city.isEmpty ? "Updated" : city
        } catch {
            status = "Weather error: \(error.localizedDescription)"
        }
    }

    private func renderLoop() async {
        let start = Date()
        while !Task.isCancelled {
            if !connection.isConnected { await connection.attemptReconnect() }
            else if hasData {
                try? await connection.send(currentSurface(phase: Date().timeIntervalSince(start)))
            }
            if let l = lastLocation, Date().timeIntervalSince(lastFetch) > 900 { await fetch(l) }   // refresh ~15 min
            try? await Task.sleep(nanoseconds: 90_000_000)
        }
    }

    /// The current scene at the given animation phase (seconds). 64×64; box-shrunk for a 16×16 panel.
    func currentSurface(phase: Double) -> Surface {
        let t = useCelsius ? tempC : tempC*9/5+32
        let h = useCelsius ? hiC : hiC*9/5+32
        let lo = useCelsius ? loC : loC*9/5+32
        let s = WeatherRenderer.surface(cond: cond, isDay: isDay, temp: Int(t.rounded()), hi: Int(h.rounded()), lo: Int(lo.rounded()), phase: phase)
        return connection.profile.width == 64 ? s : shrink(s, to: connection.profile.width)
    }

    private func shrink(_ s: Surface, to size: Int) -> Surface {
        guard size < 64, 64 % size == 0 else { return s }
        let f = 64 / size; var out = Surface(width: size, height: size)
        for oy in 0..<size { for ox in 0..<size {
            var r=0, g=0, b=0
            for dy in 0..<f { for dx in 0..<f { let p=s.at(ox*f+dx, oy*f+dy); r+=Int(p.red); g+=Int(p.green); b+=Int(p.blue) } }
            let n=f*f; out.set(ox, oy, PixelRGB(red: UInt8(r/n), green: UInt8(g/n), blue: UInt8(b/n)))
        }}
        return out
    }
}

// MARK: - View

struct WeatherView: View {
    @EnvironmentObject private var connection: TimeboxConnection
    @StateObject private var engine: WeatherEngine
    init(connection: TimeboxConnection) { _engine = StateObject(wrappedValue: WeatherEngine(connection: connection)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TimelineView(.periodic(from: Date(), by: 0.1)) { ctx in
                    Group {
                        if engine.hasData {
                            wxImage(engine.currentSurface(phase: ctx.date.timeIntervalSince1970))
                                .resizable().interpolation(.none).aspectRatio(1, contentMode: .fit)
                        } else {
                            RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.15))
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(ProgressView())
                        }
                    }
                    .frame(maxWidth: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)))
                }
                .padding(.top, 8)

                VStack(spacing: 4) {
                    Text(engine.city.isEmpty ? engine.status : engine.city).font(.headline)
                    if !engine.conditionText.isEmpty { Text(engine.conditionText).font(.subheadline).foregroundStyle(.secondary) }
                }

                Picker("Units", selection: $engine.useCelsius) {
                    Text("°F").tag(false); Text("°C").tag(true)
                }
                .pickerStyle(.segmented).frame(maxWidth: 200)

                Text("Live weather for your location from Apple Weather, streamed to the device. \(connection.profile.width == 64 ? "" : "Best on a Pixoo 64.")")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)

                Link("Weather data provided by  Weather", destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("Weather")
        .onAppear { engine.start() }
        .onDisappear { engine.stop() }
    }
}

private func wxImage(_ s: Surface) -> Image {
    let w = s.width, h = s.height
    var bytes = [UInt8](repeating: 255, count: w*h*4)
    for i in 0..<s.pixels.count { let p = s.pixels[i]; bytes[i*4]=p.red; bytes[i*4+1]=p.green; bytes[i*4+2]=p.blue; bytes[i*4+3]=255 }
    let cs = CGColorSpaceCreateDeviceRGB()
    if let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                           space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = ctx.makeImage() {
        return Image(decorative: cg, scale: 1)
    }
    return Image(systemName: "cloud.sun")
}
