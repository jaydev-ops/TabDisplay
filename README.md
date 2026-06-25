# 🖥️ TabDisplay

TabDisplay is a ultra-low-latency, hardware-accelerated secondary display mirroring solution designed to extend your macOS desktop onto a Samsung Tab S6 Lite (or any Android tablet) over Wi-Fi (UDP) or USB (TCP ADB Tunneling).

---

## 🚀 Key Features

* **Ultra-Low Latency**: End-to-end latency **under 40ms** over USB (Wired ADB mode) and **under 80ms** over local 5GHz Wi-Fi.
* **Low Overhead Video Stream**: macOS screen capture utilizes Apple's unified memory `ScreenCaptureKit` and `VideoToolbox` H.264 Baseline encoding to avoid CPU-to-GPU copies.
* **Selective Repeat ARQ**: Custom UDP network stack with lightweight NACK-based frame reassembly for packet drop resilience over wireless networks.
* **Wired USB Connection**: Instant ADB port forwarding auto-connection over standard USB.
* **Touch Event Forwarding**: Multi-touch and gesture events mapped from Android back into native macOS `CGEvent` mouse coordinates.
* **Adaptive Bitrate & Resolution (ABR)**: Dynamic network quality telemetry profiling every 500ms automatically tunes target bitrate and shifts capture resolution (0.75x) to maintain stable frame rates.

---

## 🛠️ Architecture Overview

```
 ┌──────────────────────────┐                   ┌──────────────────────────┐
 │       macOS Server       │                   │      Android Client      │
 │  (TabDisplay.app)        │                   │      (TabDisplay.apk)    │
 ├──────────────────────────┤                   ├──────────────────────────┤
 │                          │  ◄── Handshake ───│                          │
 │  ControlServer (TCP)     │  ─── Response ──► │  ControlClient (TCP)     │
 │  [Port: 5001]            │  ◄── Telemetry ───│  [Port: 5001]            │
 │                          │  ◄── InputEvents ─│                          │
 ├──────────────────────────┤                   ├──────────────────────────┤
 │                          │                   │  ClientNetwork           │
 │  ServerNetwork (UDP/TCP) │  ── Video Frames ─│  (UDP Datagram Socket/   │
 │  [Port: 6002]            │     [H.264] ────► │   TCP Socket)            │
 └──────────────────────────┘                   └──────────────────────────┘
```

---

## 📦 Installation & Setup

### 1. macOS Server Installation
1. Mount the `TabDisplay.dmg` installer.
2. Drag `TabDisplay.app` to your `Applications/` folder.
3. Launch `TabDisplay` (you will see a 🖥️ icon in the menu bar).
4. **Mandatory step**: Go to **System Settings → Privacy & Security → Accessibility** and grant permission to `TabDisplay`.

### 2. Android Client Setup
1. Copy and install `TabDisplay.apk` onto your tablet.
2. Enable developer mode on your tablet: Go to **Settings → About Tablet → Software Information** and tap **Build Number** 7 times.
3. Go back to **Settings → Developer Options** and enable **USB Debugging**.

---

## 🔌 Connection Modes

### Mode A: Wired USB Mode (Recommended for < 40ms Latency)
1. Connect the tablet to your Mac using a USB-C cable.
2. Trust the computer on the tablet screen when prompted.
3. Open a terminal on your Mac and run the tunnel initializer script:
   ```bash
   ./scripts/setup_usb_tunnel.sh
   ```
4. Enable **USB Mode** in the macOS menu bar dropdown (or ⌘U).
5. Open the tablet app and toggle the **USB Mode** switch ON (this auto-fills `127.0.0.1`).
6. Tap **Connect**.

### Mode B: Wi-Fi Mode
1. Ensure both your Mac and Android tablet are connected to the same local 5GHz Wi-Fi router.
2. Open the tablet app.
3. Enter your Mac's local IP address (shown in System Settings or terminal).
4. Make sure **USB Mode** toggles are OFF on both sides.
5. Tap **Connect**.

---

## 🛠️ Build from Source

### Prerequisites
* macOS: Xcode 15+ / Swift 5.9+ / Homebrew / `android-platform-tools` (`brew install android-platform-tools`).
* Java Development Kit (JDK 17).

### Package Release Script
Run the automated packaging script in the root directory:
```bash
./scripts/package_release.sh
```
This compiles the release target binaries, packages the macOS app into `release/TabDisplay.dmg`, compiles the Android debug APK into `release/TabDisplay.apk`, and summarizes the outputs.

---

## 💡 Troubleshooting

* **Black Screen / No Mirroring**: Verify that the Accessibility permission is enabled for the app. If the virtual display isn't captured, toggle the listener OFF and ON.
* **USB Device Not Found**: Run `adb devices` to make sure your computer sees the connected Android device. Ensure the USB cable is fully plugged in and supports data transfer.
* **Frame Drops/Stutter**: Ensure you are using a 5GHz Wi-Fi router rather than 2.4GHz when in wireless mode, or plug in via USB for the most responsive streaming pipeline.
