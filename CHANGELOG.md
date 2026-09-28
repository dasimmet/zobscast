# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.2] - 2026-09-29

### Added
- Configurable Chromecast destination port in OBS and web settings, including `IP:port` entries and ports reported by discovered devices.

### Changed
- Migrated Cast, HTTP streaming, and mDNS networking to Zig's `std.Io` APIs with a shared threaded I/O backend.
- Replaced manual Qt dynamic-library loading with `std.DynLib` on supported platforms.

## [0.0.1] - 2026-09-28

### Added
- Initial public release of **Zobscast** — a native Chromecast output plugin for OBS Studio.
- **In-memory fragmented MP4 muxing** using embedded FFmpeg (`libavformat`, `libavcodec`) via [allyourcodebase/ffmpeg](https://github.com/allyourcodebase/ffmpeg). No external `ffmpeg` binary required.
- **Zero-dependency mDNS device discovery** (`_googlecast._tcp.local`, UDP 224.0.0.251:5353) for auto-detecting Chromecast devices on the local network.
- **Native CastV2 protocol client**: TLS on port 8009, protobuf wire framing, Default Media Receiver (`CC1AD845`) launch and media load, async keep-alive heartbeats.
- **Embedded HTTP streaming server**: serves the live fragmented MP4 stream directly to the Chromecast.
- **Web-based settings UI** served at `http://127.0.0.1:<port>/settings` and opened in a native Qt WebView or system browser via OBS Tools menu.
- **Tools menu integration**: `Zobscast: Options` and `Zobscast: Toggle` entries.
- Cross-platform support: **Linux** (x86_64, aarch64), **Windows** (x86_64), **macOS** (x86_64, aarch64).
- Translations for all languages shipped with OBS Studio.
- Built entirely with **Zig** 0.17-dev; zero shell-out subprocess dependencies.

### Changed
- Settings are stored in `zobscast.json` in the OBS plugin config directory and survive OBS restarts.

[Unreleased]: https://github.com/dasimmet/zobscast/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/dasimmet/zobscast/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/dasimmet/zobscast/releases/tag/v0.0.1
