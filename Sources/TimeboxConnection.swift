import SwiftUI
import TimeboxKit
import TimeboxBluetooth

/// One shared connection to the Timebox, injected into every module via the
/// SwiftUI environment. Wraps the library's `TimeboxClient`.
@MainActor
final class TimeboxConnection: ObservableObject {
    @Published var status = "Not connected"
    @Published var isConnected = false
    @Published var busy = false

    private let client = TimeboxClient()

    init() {
        // The library auto-reconnects after an unexpected drop; reflect the live state
        // and re-apply brightness when the link comes back.
        client.onConnectionChange = { [weak self] connected in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isConnected = connected
                self.status = connected ? "Connected" : "Reconnecting…"
                if connected { Task { try? await self.client.setBrightness(100) } }
            }
        }
    }

    func connect() {
        guard !busy else { return }
        busy = true
        status = "Connecting…"
        Task {
            do {
                try await client.connect()
                isConnected = client.isConnected
                status = isConnected ? "Connected" : "Connected (no RX characteristic)"
                if isConnected { try? await client.setBrightness(100) }
            } catch {
                isConnected = false
                status = "Connect failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    func disconnect() {
        client.disconnect()
        isConnected = false
        status = "Disconnected"
    }

    // Module-facing API (mirrors TimeboxClient).
    func send(_ frame: PixelFrame) async throws { try await client.send(image: frame) }
    func setColor(_ color: PixelRGB) async throws { try await client.setColor(color) }
    func setBrightness(_ percent: Int) async throws { try await client.setBrightness(percent) }

    /// Note a send failure from a module so the UI reflects a dropped connection.
    func noteDisconnected(_ message: String) {
        isConnected = false
        status = message
    }
}
