import SwiftUI
import TimeboxKit

struct ContentView: View {
    @StateObject private var box = LibraryClient()

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    Text(box.status).font(.callout)
                    HStack {
                        Button("Scan & Connect") { box.connect() }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Disconnect") { box.disconnect() }
                            .foregroundStyle(.red)
                    }
                }

                if box.isConnected {
                    Section("Brightness") {
                        Button("Brightness 100%") { box.setBrightness(100) }
                        Button("Brightness 5%") { box.setBrightness(5) }
                    }
                    Section("Color") {
                        Button("Red") { box.setColor(PixelRGB(red: 255, green: 0, blue: 0)) }
                        Button("Green") { box.setColor(PixelRGB(red: 0, green: 255, blue: 0)) }
                        Button("Blue") { box.setColor(PixelRGB(red: 0, green: 0, blue: 255)) }
                    }
                    Section("Images") {
                        Button("Test pattern (4 quadrants)") { box.sendImage(Self.quadrantFrame()) }
                        Button("Test image (gradient)") { box.sendImage(Self.gradientFrame()) }
                    }
                }
            }
            .navigationTitle("Timebox iOS")
        }
    }

    /// Distinct low-color pattern: top-left red, top-right green, bottom-left blue,
    /// bottom-right white — confirms the image path and orientation.
    private static func quadrantFrame() -> PixelFrame {
        var pixels = [PixelRGB]()
        for y in 0..<16 {
            for x in 0..<16 {
                let left = x < 8, top = y < 8
                let c: PixelRGB
                if top && left { c = PixelRGB(red: 255, green: 0, blue: 0) }
                else if top && !left { c = PixelRGB(red: 0, green: 255, blue: 0) }
                else if !top && left { c = PixelRGB(red: 0, green: 0, blue: 255) }
                else { c = PixelRGB(red: 255, green: 255, blue: 255) }
                pixels.append(c)
            }
        }
        return (try? PixelFrame(pixels: pixels)) ?? PixelFrame()
    }

    private static func gradientFrame() -> PixelFrame {
        var pixels = [PixelRGB]()
        for y in 0..<16 {
            for x in 0..<16 {
                pixels.append(PixelRGB(red: UInt8(x * 17), green: UInt8(y * 17), blue: 128))
            }
        }
        return (try? PixelFrame(pixels: pixels)) ?? PixelFrame()
    }
}
