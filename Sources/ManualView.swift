import SwiftUI
import TimeboxKit

/// Manual test module — brightness, solid colors, and two test images. Useful for
/// verifying the connection and the image path independent of the Now Playing loop.
struct ManualView: View {
    @EnvironmentObject private var connection: TimeboxConnection
    @State private var status = ""

    var body: some View {
        List {
            Section("Brightness") {
                Button("Brightness 100%") { run("brightness 100") { try await connection.setBrightness(100) } }
                Button("Brightness 5%") { run("brightness 5") { try await connection.setBrightness(5) } }
            }
            Section("Color") {
                Button("Red") { run("red") { try await connection.setColor(PixelRGB(red: 255, green: 0, blue: 0)) } }
                Button("Green") { run("green") { try await connection.setColor(PixelRGB(red: 0, green: 255, blue: 0)) } }
                Button("Blue") { run("blue") { try await connection.setColor(PixelRGB(red: 0, green: 0, blue: 255)) } }
            }
            Section("Images") {
                Button("Test pattern (4 quadrants)") { run("quadrants") { try await connection.send(Self.quadrantFrame()) } }
                Button("Test image (gradient)") { run("gradient") { try await connection.send(Self.gradientFrame()) } }
            }
            if !status.isEmpty {
                Section("Status") { Text(status).font(.caption) }
            }
        }
        .navigationTitle("Manual")
    }

    private func run(_ label: String, _ op: @escaping () async throws -> Void) {
        Task {
            do { try await op(); status = "sent \(label)" }
            catch { status = "\(label) failed: \(error.localizedDescription)" }
        }
    }

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
