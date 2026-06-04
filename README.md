# Pixel Labs

An iOS app that controls a **Divoom Timebox Evo** (16×16 LED display) over BLE — a Now
Playing module (album art + analog/digital clocks with a scrolling title) plus brightness,
solid color, and arbitrary 16×16 images — built entirely on the shared
[`TimeboxClient`](../TimeBox) library (`TimeboxKit` + `TimeboxBluetooth`). No app-specific
Bluetooth code: the BLE/RCSP transport lives in the library.

> **Unofficial.** Pixel Labs is not affiliated with, authorized, or endorsed by Divoom.
> "Divoom" and "Timebox" are trademarks of their respective owners; they're used here only
> to describe the compatible hardware. The protocol was clean-room reimplemented for
> interoperability — no Divoom code or assets are included.

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

In Xcode, select your signing team, then ⌘R to a paired iPhone. Grant Bluetooth
permission, tap **Scan & Connect**, then use the brightness / color / image buttons.

## How it talks to the device

`TimeboxClient` on iOS uses `CoreBluetoothRCSPTransport`: it wraps the Evo's SPP command
bytes in the JieLi **RCSP** framing and tunnels them through the device's `01` command
channel. See the library's `CLAUDE.md` / `README.md` for the protocol.
