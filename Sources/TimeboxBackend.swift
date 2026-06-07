import Foundation
import TimeboxBluetooth
import TimeboxKit

/// The Divoom Timebox Evo path on iOS: a 16×16 panel driven over BLE (the JieLi RCSP
/// tunnel) via the `timebox-studio` library. Adapts the device-independent `Surface` to
/// the library's fixed 16×16 `PixelFrame` at the send boundary.
///
/// Unlike the macOS backend (which enumerates paired devices and connects by address),
/// iOS `connect()` takes no target — CoreBluetooth scans for the Timebox by name. The
/// library auto-reconnects after an unexpected drop and reports it via `onConnectionChange`,
/// which this forwards so the connection's status reflects the live link.
@MainActor
final class TimeboxBackend: DisplayBackend {
    let profile = DisplayProfile.timebox
    private let client = TimeboxClient()

    /// Notified when the BLE link drops or auto-reconnects (`true` = connected). The
    /// connection wires this to keep `isConnected`/status current without polling.
    var onConnectionChange: ((Bool) -> Void)?

    init() {
        client.onConnectionChange = { [weak self] connected in
            MainActor.assumeIsolated {
                guard let self else { return }
                if connected { Task { try? await self.client.setBrightness(100) } }
                self.onConnectionChange?(connected)
            }
        }
    }

    var isConnected: Bool { client.isConnected }
    var label: String { "Timebox" }

    func connect() async throws {
        try await client.connect()
        try? await client.setBrightness(100)
    }

    func setBrightness(_ percent: Int) async throws {
        try await client.setBrightness(percent)
    }

    func send(_ surface: Surface) async throws {
        try await client.send(image: try surface.toPixelFrame())
    }

    func disconnect() {
        client.disconnect()
    }
}
