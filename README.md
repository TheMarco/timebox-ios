# PixelFlow

An iOS app that drives a Divoom LED display — a **Timebox Evo** (16×16) over Bluetooth or a
**Pixoo 64** (64×64) over Wi-Fi — with a Now Playing module (album art + analog/digital
clocks with a scrolling title) plus brightness, solid color, and test images. The Timebox
path is built on the shared [`TimeboxClient`](../TimeBox) library (`TimeboxKit` +
`TimeboxBluetooth`); the Pixoo path talks to the device's HTTP JSON API directly.

The render loop works in a device-independent `Surface` (any square size). A `DisplayBackend`
adapts it per device: `TimeboxBackend` streams 16×16 `PixelFrame`s over BLE, while
`PixooBackend` serializes 64×64 RGB to base64 over HTTP and drives the Pixoo's own engine
(static frames + native scrolling text + brightness fades), since its HTTP round-trips can't
sustain smooth frame streaming. This mirrors the macOS *Timebox Now Playing* app.

> **Unofficial.** PixelFlow is not affiliated with, authorized, or endorsed by Divoom.
> "Divoom", "Timebox" and "Pixoo" are trademarks of their respective owners; they're used
> here only to describe the compatible hardware. The protocols were clean-room reimplemented
> for interoperability — no Divoom code or assets are included.

## Build

Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is generated and
git-ignored — regenerate it before opening:

```sh
xcodegen generate
open TimeboxiOS.xcodeproj
```

The project depends on the sibling Swift package at `../TimeBox`, so keep both repos
checked out next to each other:

```
projects/GIT/
  TimeBox/        # the library (TimeboxKit, TimeboxBluetooth)
  timebox-ios/    # this app
```

In Xcode, select your signing team, then ⌘R to a paired iPhone. On the home screen, pick a
display to connect to:

- **Connect Timebox (Bluetooth)** — scans for a Timebox Evo by name (grant Bluetooth
  permission on first use).
- **Find Pixoo 64 on Wi-Fi** — asks Divoom's cloud which devices share your network's public
  IP and connects to the first one.
- **Enter Pixoo 64 IP…** — connect directly by IP (find it in the Divoom app under the
  device's settings). The first connect triggers the iOS local-network permission prompt;
  tap **Allow** and it retries automatically.

Then open **Now Playing** (album art + clocks) or **Manual test** (brightness / color /
test images).

## How it talks to the devices

**Timebox (Bluetooth).** `TimeboxClient` on iOS uses `CoreBluetoothRCSPTransport`: it wraps
the Evo's SPP command bytes in the JieLi **RCSP** framing and tunnels them through the
device's `01` command channel. See the library's `CLAUDE.md` / `README.md` for the protocol.

**Pixoo 64 (Wi-Fi).** `PixooBackend` POSTs JSON to the device's HTTP API
(`http://<ip>/post`): `Draw/SendHttpGif` carries a base64 RGB frame, `Draw/SendHttpText`
drives the firmware's native scrolling text, and `Channel/SetBrightness` paces the
fade-through-black transitions. Plain-`http` to a local IP is allowed via
`NSAllowsLocalNetworking` while App Transport Security stays on for everything else.
