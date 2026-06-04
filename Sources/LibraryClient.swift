import SwiftUI
import TimeboxKit
import TimeboxBluetooth

/// Thin SwiftUI view-model over the shared `TimeboxClient` library API. The whole BLE
/// path (CoreBluetooth + RCSP + the 01 command channel) now lives in TimeboxBluetooth;
/// this app just calls `connect()` / `setBrightness` / `setColor` / `send(image:)` —
/// the exact same API a macOS app uses.
@MainActor
final class LibraryClient: ObservableObject {
    @Published var status = "Idle"
    @Published var isConnected = false

    private let client = TimeboxClient()

    func connect() {
        status = "Connecting…"
        Task {
            do {
                try await client.connect()
                isConnected = client.isConnected
                status = isConnected ? "Connected — ready" : "Connected (no RX characteristic)"
            } catch {
                isConnected = false
                status = "Connect failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        client.disconnect()
        isConnected = false
        status = "Disconnected"
    }

    func setBrightness(_ percent: Int) { run("brightness \(percent)") { try await self.client.setBrightness(percent) } }
    func setColor(_ color: PixelRGB) { run("color") { try await self.client.setColor(color) } }
    func sendImage(_ frame: PixelFrame) { run("image") { try await self.client.send(image: frame) } }

    private func run(_ label: String, _ op: @escaping () async throws -> Void) {
        Task {
            do { try await op(); status = "sent \(label)" }
            catch { status = "\(label) failed: \(error.localizedDescription)" }
        }
    }
}
