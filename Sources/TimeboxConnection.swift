import SwiftUI
import TimeboxKit

/// One shared connection to the active display — a 16×16 Divoom Timebox Evo over BLE or a
/// 64×64 Divoom Pixoo 64 over Wi-Fi — injected into every module via the SwiftUI
/// environment. Wraps a `DisplayBackend`, so modules render into a device-independent
/// `Surface` and the backend adapts it (PixelFrame over BLE, base64 RGB over HTTP).
@MainActor
final class TimeboxConnection: ObservableObject {
    @Published var status = "Not connected"
    @Published var isConnected = false
    @Published var busy = false
    /// Geometry/timing of the connected device, so modules size their renders. Defaults to
    /// the Timebox until a backend connects.
    @Published private(set) var profile = DisplayProfile.timebox

    /// The active backend. Exposed so a module can drive a device's native engine (the Pixoo's
    /// smooth scrolling-text / fade path). Nil when disconnected.
    private(set) var backend: DisplayBackend?

    /// Which backend to restore on next launch.
    enum BackendKind: String { case timebox, pixoo }

    // MARK: - Connect

    /// Connect to a Timebox over BLE. CoreBluetooth scans for it by name; the library
    /// auto-reconnects after a drop and reports it via the backend's `onConnectionChange`.
    func connectTimebox() {
        guard !busy else { return }
        let bt = TimeboxBackend()
        bt.onConnectionChange = { [weak self, weak bt] connected in
            guard let self else { return }
            self.isConnected = connected
            self.status = connected ? "Connected: \(bt?.label ?? "Timebox")" : "Reconnecting…"
        }
        start(backend: bt, kind: .timebox, connecting: "Scanning & connecting…")
    }

    /// Connect to a Pixoo 64 at an explicit IP (64×64, Wi-Fi). The address is remembered.
    func connectPixoo(host: String) {
        guard !busy else { return }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Keys.pixooHost)
        start(backend: PixooBackend(host: trimmed), kind: .pixoo, connecting: "Connecting to Pixoo \(trimmed)…")
    }

    /// Auto-discover a Pixoo on the LAN (via Divoom's cloud), then connect to it.
    func connectPixooAuto() {
        guard !busy else { return }
        busy = true
        status = "Searching for a Pixoo on your network…"
        Task {
            let found = await PixooBackend.discover()
            busy = false
            guard let device = found.first else {
                status = "No Pixoo found — try entering its IP address."
                return
            }
            connectPixoo(host: device.host)
        }
    }

    private func start(backend newBackend: DisplayBackend, kind: BackendKind, connecting message: String) {
        teardown()                         // tear down any existing link first
        busy = true
        backend = newBackend
        profile = newBackend.profile
        status = message
        Task {
            do {
                try await newBackend.connect()
                isConnected = true
                status = "Connected: \(newBackend.label)"
                persistRestore(kind)        // resume this device next launch
            } catch {
                isConnected = false
                backend = nil
                status = "Connect failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    func disconnect() {
        UserDefaults.standard.set(false, forKey: Keys.autoConnect)   // explicit — stay disconnected
        teardown()
        status = "Disconnected"
    }

    private func teardown() {
        backend?.disconnect()
        backend = nil
        isConnected = false
    }

    // MARK: - Restore

    /// On launch, reconnect automatically to the last device if we were connected last time
    /// (and the user didn't explicitly disconnect).
    func autoConnect() {
        guard !isConnected, !busy, UserDefaults.standard.bool(forKey: Keys.autoConnect) else { return }
        switch restoredKind {
        case .pixoo:
            let host = UserDefaults.standard.string(forKey: Keys.pixooHost) ?? ""
            if host.isEmpty { connectTimebox() } else { connectPixoo(host: host) }
        case .timebox:
            connectTimebox()
        }
    }

    private func persistRestore(_ kind: BackendKind) {
        let d = UserDefaults.standard
        d.set(true, forKey: Keys.autoConnect)
        d.set(kind.rawValue, forKey: Keys.backendKind)
    }

    private var restoredKind: BackendKind {
        BackendKind(rawValue: UserDefaults.standard.string(forKey: Keys.backendKind) ?? "") ?? .timebox
    }

    /// Last Pixoo IP, to prefill the manual-entry field.
    var lastPixooHost: String { UserDefaults.standard.string(forKey: Keys.pixooHost) ?? "" }

    private enum Keys {
        static let autoConnect = "conn.autoConnect"
        static let backendKind = "conn.backendKind"
        static let pixooHost = "conn.pixooHost"
    }

    // MARK: - Module-facing API

    /// Send a frame. On the HTTP (Pixoo) path a failed send means the link is down, so
    /// reflect it and let the loop reconnect; BLE drops are reported via onConnectionChange.
    func send(_ surface: Surface) async throws {
        guard let backend else { throw PixooError.unreachable("display") }
        do {
            try await backend.send(surface)
        } catch is CancellationError {
            throw CancellationError()   // navigating away cancels the in-flight send — not a drop
        } catch {
            if backend.profile.drivesNatively { isConnected = false }
            throw error
        }
    }

    func setBrightness(_ percent: Int) async throws {
        try await backend?.setBrightness(percent)
    }

    /// Fill the whole panel with one color (a solid `Surface` sized to the device).
    func setColor(_ color: PixelRGB) async throws {
        try await send(Surface(width: profile.width, height: profile.height, fill: color))
    }

    /// Re-establish the link after a drop. Only the HTTP (Pixoo) backend needs this; the
    /// BLE library auto-reconnects on its own.
    func attemptReconnect() async {
        guard let backend, backend.profile.drivesNatively else { return }
        do {
            try await backend.connect()
            isConnected = true
            status = "Connected: \(backend.label)"
        } catch {
            isConnected = false
        }
    }
}
