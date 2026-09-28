# Zobscast

**Zobscast** is a native OBS Studio output plugin that streams your OBS canvas live to any Chromecast or Google Cast-compatible device on your local network.

[![GitHub Release](https://img.shields.io/github/v/release/dasimmet/zobscast)](https://github.com/dasimmet/zobscast/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Features

- **Zero external dependencies** — no `ffmpeg` binary, no `mkchromecast`, no FIFOs, no shell scripts.
- **Native Chromecast (CastV2) protocol** — TLS control channel on port 8009, protobuf wire framing, Default Media Receiver launch and media load, async heartbeat.
- **Automatic device discovery** — multicast DNS (`_googlecast._tcp.local`) finds Cast devices and shows friendly names.
- **In-memory fragmented MP4 muxer** — uses embedded FFmpeg libraries for live H.264 + AAC streaming without any temporary files.
- **Built-in HTTP streaming server** — serves the live MP4 stream directly to the Chromecast at the correct LAN address.
- **Web settings UI** — opens in a native Qt WebView (or system browser as fallback) from the OBS Tools menu.
- **Cross-platform** — Linux, Windows, and macOS; x86_64 and aarch64.
- **Fully translated** — all strings use OBS Studio's localization system; ships translations for every language OBS supports.

---

## Installation

Download the latest release for your platform from the [Releases page](https://github.com/dasimmet/zobscast/releases).

### Linux (x86_64 / aarch64)
```bash
mkdir -p ~/.config/obs-studio/plugins/zobscast/bin/64bit
cp zobscast.so ~/.config/obs-studio/plugins/zobscast/bin/64bit/
cp -r data ~/.config/obs-studio/plugins/zobscast/
```

### Windows (x86_64)
Copy the files to:
- `%APPDATA%\obs-studio\plugins\zobscast\bin\64bit\zobscast.dll`
- `%APPDATA%\obs-studio\plugins\zobscast\data\`

### macOS (x86_64 / aarch64)
```bash
mkdir -p ~/Library/Application\ Support/obs-studio/plugins/zobscast
cp -r bin data ~/Library/Application\ Support/obs-studio/plugins/zobscast/
```

---

## Usage

1. **Start OBS Studio** — the plugin is loaded automatically.
2. Open **Tools → Zobscast: Options** to configure settings.
3. Click **Scan** to find Chromecast devices on your network, or enter an IP address manually.
4. Adjust the bitrate and encoder preset, then **Save Settings**.
5. Click **Tools → Zobscast: Toggle** to start or stop casting.

---

## Network Requirements

| Port | Protocol      | Direction | Purpose                                           |
| ---- | ------------- | --------- | ------------------------------------------------- |
| 5353 | UDP multicast | out       | mDNS device discovery                             |
| 8009 | TCP (TLS)     | out       | CastV2 control channel                            |
| auto | TCP (HTTP)    | in        | Media stream (Chromecast pulls from your machine) |

---

## Building from Source

### Requirements
- Zig **0.17.0-dev**

```bash
# Debug build
zig build

# Optimized release build
zig build -Doptimize=ReleaseFast

# Cross-compile for Windows
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast

# Cross-compile for macOS arm64
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
```

Outputs are placed in `zig-out/bin/`:
| Platform       | Path                               |
| -------------- | ---------------------------------- |
| Linux x86_64   | `zig-out/bin/64bit/zobscast.so`    |
| Linux aarch64  | `zig-out/bin/64bit/zobscast.so`    |
| Windows x86_64 | `zig-out/bin/64bit/zobscast.dll`   |
| macOS x86_64   | `zig-out/bin/64bit/zobscast.dylib` |
| macOS aarch64  | `zig-out/bin/64bit/zobscast.dylib` |

---

## Architecture

```
OBS Studio
├── Video + Audio encoder (x264 / ffmpeg_aac)
│   └── encoded H.264 + AAC packets
│       └── Muxer.zig  ──── fragmented MP4 (in-memory)
│           └── Server.zig ─── HTTP server  ──→ Chromecast
└── Discovery.zig  ─── mDNS scan ──→ device list
    └── Client.zig  ─── CastV2 TLS ──→ LAUNCH + LOAD media URL
```

**Source files:**
| File                                     | Purpose                                            |
| ---------------------------------------- | -------------------------------------------------- |
| [`src/root.zig`](src/root.zig)           | OBS module entry point, Tools menu, locale         |
| [`src/Output.zig`](src/Output.zig)       | OBS output plugin, encoder setup, stream lifecycle |
| [`src/Muxer.zig`](src/Muxer.zig)         | In-memory fragmented MP4 muxer (FFmpeg)            |
| [`src/Server.zig`](src/Server.zig)       | Non-blocking HTTP streaming server                 |
| [`src/Discovery.zig`](src/Discovery.zig) | Zero-dependency mDNS Chromecast discovery          |
| [`src/Client.zig`](src/Client.zig)       | CastV2 TLS protocol client                         |
| [`src/gui.zig`](src/gui.zig)             | Qt WebView settings window                         |
| [`src/obs_api.h`](src/obs_api.h)         | Minimal OBS C API declarations                     |

---

## License

[MIT](LICENSE) — Copyright (c) 2026 Tobias Simmetsreiter
