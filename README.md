# KeepInput

A tiny macOS menu bar app that keeps your chosen microphone as the default input.

When Bluetooth headphones with a mic connect, macOS switches the system input to the headset mic, which drops audio quality to low-bandwidth call mode. KeepInput watches the default input device and switches it straight back to the one you picked.

## Features

- Menu bar only (no Dock icon)
- Remembers the locked input across restarts (stored by device UID)
- Re-applies the lock when the chosen device reconnects
- Lists only physical input devices (hides virtual drivers like Teams/Zoom)
- Launch at Login toggle

## Build

Open `KeepInput.xcodeproj` in Xcode and build, or:

```bash
xcodebuild -project KeepInput.xcodeproj -scheme KeepInput -configuration Release build
```

Requires macOS 26.5+.
