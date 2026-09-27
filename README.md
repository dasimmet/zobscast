# Zobscast: Native Chromecast Plugin for OBS Studio

**Zobscast** is a cross-platform OBS Studio output plugin written in [Zig](https://ziglang.org/) (Zig 0.16.0). It allows you to cast your live OBS stream directly to Google Cast / Chromecast devices on your local network—completely in memory, with zero external CLI dependencies.

---

## Key Features

- **Embedded In-Memory FFmpeg Muxer**:
  - Replaces external `ffmpeg` command-line processes with in-tree `libffmpeg` bindings (`allyourcodebase/ffmpeg`).
  - Muxes H.264/AAC frames into live fragmented MP4 (`frag_keyframe+empty_moov+default_base_moof`) directly in memory via custom `AVIOContext` callbacks.

- **Native Chromecast & mDNS Implementation**:
  - Replaces `mkchromecast` with native Zig code in this repository.
  - **Zero-Dependency mDNS Discovery**: Performs multicast DNS queries (`_googlecast._tcp.local` on `224.0.0.251:5353`) to auto-detect Cast devices with friendly names and models.
  - **Embedded HTTP Streaming Server**: Serves the live fragmented MP4 stream to the Chromecast over a lightweight non-blocking HTTP socket server. Automatically resolves the correct host LAN IP facing the target device.
  - **Native CastV2 Client**: Handles TLS communication on port `8009`, protobuf wire framing, Default Media Receiver application launching (`CC1AD845`), media payload loading, and asynchronous keep-alive heartbeats.

- **Zero FIFOs & Cross-Platform Compatible**:
  - Eliminates `/tmp/mkchromecast.fifo.mp4` and OS-specific shell commands (`mkfifo`, `rm`).
  - Memory-safe stream forwarding designed to run across Linux, Windows, and macOS.

- **OBS Studio GUI Integration**:
  - Adds **Tools $\rightarrow$ Zobscast: Options** to directly open the native configuration dialog anytime.
  - Adds **Tools $\rightarrow$ Zobscast: Toggle** to start/stop live streaming with one click.
  - Registers the **Zobscast** input source type under Sources, allowing you to configure sink settings and encoder options directly from Source Properties.
  - Provides an auto-populated **Cast Sink** dropdown list with friendly Chromecast device names discovered via mDNS, a **Scan for Devices** button, manual IP entry, and configurable bitrates and encoder presets.
  - Automatically saves settings to `zobscast.json` in OBS's plugin configuration directory.

---

## Architecture Overview

```
+-------------------------------------------------------------------+
|                            OBS Studio                             |
|                                                                   |
|   +-----------------------+              +--------------------+   |
|   |  OBS Video/Audio Out  |              | Output Properties  |   |
|   +-----------+-----------+              +---------+----------+   |
+---------------|------------------------------------|--------------+
                | Raw H.264/AAC frames               | Device selection
                v                                    v
+-------------------------------+          +--------------------+
|       src/ffmpeg/Muxer.zig    |          | src/cast/Discovery |
|   (In-memory fragmented MP4)  |          | (mDNS on UDP 5353) |
+---------------+---------------+          +---------+----------+
                | Muxed fMP4 chunks                  | IP & Port
                v                                    v
+-------------------------------+          +--------------------+
|      src/stream/Server.zig    |          |  src/cast/Client   |
|  (Non-blocking HTTP Server    |          | (CastV2 TLS 8009:  |
|       at port 8010)           |          |  LAUNCH & LOAD)    |
+---------------+---------------+          +---------+----------+
                |                                    |
                | HTTP Stream (http://<host>:8010)   | TLS Control Session
                v                                    v
    +----------------------------------------------------+
    |             Google Cast / Chromecast               |
    +----------------------------------------------------+
```

### Source File Structure

- [`src/root.zig`](src/root.zig): OBS module entry point (`obs_module_load`, `obs_module_unload`), locale loaders, and Tools menu hook.
- [`src/Output.zig`](src/Output.zig): OBS output plugin implementation (`obs_output_info`), property controls, and stream lifecycle management.
- [`src/ffmpeg/Muxer.zig`](src/ffmpeg/Muxer.zig): In-memory fragmented MP4 container muxer using `libffmpeg`.
- [`src/stream/Server.zig`](src/stream/Server.zig): Non-blocking HTTP streaming server broadcasting video chunks to connected clients.
- [`src/cast/Discovery.zig`](src/cast/Discovery.zig): Zero-dependency mDNS listener for device discovery.
- [`src/cast/Client.zig`](src/cast/Client.zig): CastV2 protocol client with TLS connection, protobuf serialization, and heartbeat loop.
- [`src/obs_api.h`](src/obs_api.h): Self-contained LibOBS C declarations for fast `@cImport` translation.
- [`src/zobscast.version`](src/zobscast.version): Linux ELF linker version script ensuring internal static dependencies remain local.

---

## Building

### Requirements
- [Zig](https://ziglang.org/) **0.16.0** (managed automatically if you have `anyzig` installed at `~/.local/bin/zig`).
- Standard C library (`libc`).

### Build Commands

```bash
# Debug build:
~/.local/bin/zig build

# Fast optimized release build:
~/.local/bin/zig build -Doptimize=ReleaseFast
```

The resulting dynamic library will be placed in:
- `zig-out/64bit/zobscast.so` (and `zig-out/bin/64bit/zobscast.so` on Linux)
- `zig-out/64bit/zobscast.dll` (on Windows)
- `zig-out/64bit/zobscast.dylib` (on macOS)

---

## Installation

To install the plugin into OBS Studio:

### Linux
Create the plugin directory if it does not already exist:
```bash
# directly use zig to build and instal
zig build -p ~/.config/obs-studio/plugins/zobscast/

mkdir -p ~/.config/obs-studio/plugins/zobscast/bin/64bit
mkdir -p ~/.config/obs-studio/plugins/zobscast/data

# Copy binary:
cp zig-out/bin/64bit/zobscast.so ~/.config/obs-studio/plugins/zobscast/bin/64bit/

# Copy localization data:
cp -r data/* ~/.config/obs-studio/plugins/zobscast/data/
```

### Windows
Copy the built library and data folder to:
- `%APPDATA%\obs-studio\plugins\zobscast\bin\64bit\zobscast.dll`
- `%APPDATA%\obs-studio\plugins\zobscast\data\`

### macOS
Copy the built library and data folder to:
- `~/Library/Application Support/obs-studio/plugins/zobscast/bin/zobscast.dylib`
- `~/Library/Application Support/obs-studio/plugins/zobscast/data/`

---

## Usage in OBS Studio

1. **Launch OBS Studio**: Zobscast will be detected and loaded automatically on startup.
2. **Access Output & Cast Options**:
   - Click **Tools $\rightarrow$ Zobscast Options** in the top menu bar to open the options dialog directly.
   - Alternatively, add a **Zobscast** source in your Scenes/Sources dock and open its **Properties**.
3. **Configure Sink & Encoder**:
   - Click **Scan for Devices** to search for available Chromecasts on the local network.
   - Select your target device from the **Cast Destination** drop-down menu, or manually type the device's IP address.
   - Adjust the **Bitrate** (kbps) and **Encoder Preset** as desired.
   - Click OK — your settings are saved automatically to `zobscast.json` across OBS restarts.
4. **Start / Stop Casting**:
   - Click **Tools $\rightarrow$ Zobscast: Toggle** in the top menu bar to start streaming.
   - Click **Tools $\rightarrow$ Zobscast: Toggle** again to disconnect and stop streaming.

---

## Network & Firewall Requirements

Zobscast communicates directly over your local area network (LAN):
- **UDP Port 5353**: Multicast DNS (mDNS) discovery (`224.0.0.251`).
- **TCP Port 8009**: Outgoing TLS control connection to the Chromecast.
- **TCP Port 8010**: Incoming HTTP stream connection from the Chromecast to your host machine.

Ensure that your host firewall allows traffic on these ports over your private/local network.

---

## License

This project is licensed under the GPL/LGPL terms compatible with OBS Studio and FFmpeg. See the repository headers and licenses for details.
