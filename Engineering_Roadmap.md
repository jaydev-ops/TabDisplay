# TabDisplay — Engineering

---

## 1 Executive Summary

### 1.1 Project Overview

**TabDisplay** is a distributed, real-time display extension system designed to transform an Android tablet (specifically a Samsung Tab S6 Lite) into a low-latency secondary display for macOS (specifically an Apple Silicon M2 MacBook Air).

Modern mobile devices possess high-resolution screens and hardware-accelerated decoders, making them ideal candidates for portable external displays. TabDisplay bridges the platform gap by establishing a high-throughput, low-latency communication pipeline over wireless (Wi-Fi) and wired (USB) networks. The system consists of:

1. **macOS Server App**: Captured screen frames, encodes them via hardware acceleration, forwards input injected by the client, and manages the streaming session.
2. **Android Client App**: Receives the encoded video stream, decodes it using hardware-accelerated MediaCodec, renders it to a surface, and forwards user touch/gestures back to the server.

### 1.2 Purpose & Motivation

Professionals and developers frequently require multi-monitor setups to maintain productivity. However, physical portable monitors are single-purpose and add bulk to travel gear. Transforming an existing Android tablet into a secondary monitor provides a dual-use device (tablet and monitor) without extra hardware. Commercial solutions exist but are often closed-source, subscription-based, or exhibit high latency. TabDisplay aims to deliver a cleanly architected, open, and high-performance alternative optimized for Apple Silicon and Android.

### 1.3 Key Challenges

- **Display Virtualization on macOS**: Creating a virtual screen buffer in macOS user space that the operating system treats as an independent secondary monitor.
- **Ultra-Low End-to-End Latency**: Achieving a target latency of **sub-40ms** across the capture, encode, network, decode, and render pipeline.
- **Network Jitter & Adaptability**: Handling Wi-Fi packet loss, congestion, and varying signal strength without dropping connection or introducing visual stutter.
- **Accurate Input Mapping**: Forwarding touch inputs from the tablet's coordinate space and translating them into macOS mouse, click, and gesture events.

### 1.4 Major Risks & Mitigation

- **Private API Fragility**: If the project uses private CoreGraphics APIs (`CGVirtualDisplay`) to bypass DriverKit signing requirements, system updates might break the functionality.
  - _Mitigation_: Design a clean interface abstraction around the virtual display engine, allowing the back-end to swap between a `CGVirtualDisplay` helper and an `IOUserFramebuffer` DriverKit system extension.
- **Decoder Performance Bottlenecks**: The Samsung Tab S6 Lite contains a mid-range Exynos processor. Hardware decoding must be highly optimized to prevent frame drops.
  - _Mitigation_: Target standard H.264/AVC with baseline profile and configure low-latency decoding parameters (`KEY_LATENCY = 0`, direct rendering to surface texture).

### 1.5 Target Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                              macOS Server                              │
│                                                                        │
│ ┌─────────────────────────┐     ┌────────────────┐     ┌─────────────┐ │
│ │  Virtual Display Engine │ ──> │ ScreenCapture  │ ──> │ VideoToolbox│ │
│ │  (CGVirtualDisplay API) │     │ (SCK / Frame)  │     │ (H.264 enc) │ │
│ └─────────────────────────┘     └────────────────┘     └──────┬──────┘ │
│ ┌─────────────────────────┐                                   │        │
│ │   Input Injector        │ <────────────────────────┐        │        │
│ │   (CGEvent / Synthesis) │                          │        │        │
│ └─────────────────────────┘                          │        │        │
└──────────────────────────────────────────────────────┼────────┼───────┘
                                                       │        │
                                          Network Link │        │ Video Stream
                                          (WiFi / USB) │        │ (RTP / Raw)
                                                       │        │
┌──────────────────────────────────────────────────────┼────────┼───────┐
│                             Android Client           │        ▼       │
│                                                      │  ┌───────────┐ │
│ ┌─────────────────────────┐                          └─ │  Network  │ │
│ │    Touch Forwarder      │ ──────────────────────────> │  Receiver │ │
│ │ (MotionEvent -> Packet) │                             └─────┬─────┘ │
│ └─────────────────────────┘                                   │        │
│ ┌─────────────────────────┐     ┌────────────────┐            │        │
│ │      Render Surface     │ <── │   MediaCodec   │ <──────────┘        │
│ │    (OpenGL ES / Vulkan) │     │ (H.264 dec)    │                     │
│ └─────────────────────────┘     └────────────────┘                     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2 Feasibility Study

An analysis of the core technical requirements reveals varying levels of complexity, technical constraints, and API limitations.

### 2.1 Feasibility Categorization

#### Easy (Straightforward Implementation)

- **Android UI and Canvas**: Building the layout for the Android app, display controls, and status monitoring.
- **Basic Network Handshake**: Setting up standard TCP/UDP control channels to negotiate connections, swap capabilities, and send heartbeats.
- **Configuration Management**: Storing configuration presets (resolutions, bitrates, frame rates) on both server and client.

#### Moderate (Standard APIs, Requires Careful Design)

- **ScreenCaptureKit Integration**: macOS 12.3+ `ScreenCaptureKit` provides high-performance frame capture directly from the GPU. Writing the handler and frame buffer extractor requires proper memory management to avoid memory leaks.
- **VideoToolbox Encoding**: Initializing and managing H.264 hardware encoders via Swift. Crucial options like real-time rate control, I-frame intervals, and profile settings must be manually configured.
- **Android MediaCodec Hardware Decoding**: Using Kotlin to configure the low-latency hardware decoder. Frames must be queued and passed to an active `Surface` as soon as they arrive.
- **USB Connectivity via ADB Tunneling**: Tunneling TCP sockets over USB using `adb forward` is reliable, standard for developer tools, and requires no custom Android USB Accessory drivers.

#### Hard (High Complexity, Critical Optimization Needed)

- **Input Translation and Injection**: Translating absolute touch coordinates (with different aspect ratios and resolutions) into relative or absolute mouse movements on macOS. Support for scrolling, multi-touch pinch-to-zoom, and secondary clicks requires mapping Android gesture detectors to native `CGEvent` synthesis on macOS.
- **End-to-End Latency Control**: Maintaining a sub-40ms pipeline requires strict thread synchronization, buffer minimization (no queuing of decoded frames), packet fragmentation strategies, and custom congestion control.
- **Wireless Packet Loss Recovery**: Standard UDP is prone to frame drops which result in visual corruption (slicing or keyframe corruption). TCP is prone to "head-of-line blocking," spiking latency when packets drop. Implementing a lightweight UDP protocol with selective retransmissions (ARQ) or Forward Error Correction (FEC) is required.

#### Extremely Hard / Provisioning Entitlement Required

- **System-wide Extended Display Driver**: Creating a true virtual display that macOS recognises as a native display layout requires a DriverKit extension using `IOUserFramebuffer`. This requires:
  1. A paid Apple Developer Account.
  2. Apple approval for the DriverKit Entitlement.
  3. System Extension installation privileges.

### 2.2 Core Technical Solutions & Alternatives

#### 2.2.1 macOS Virtual Display Creation

To allow the Android device to serve as an _extended display_ rather than just mirroring a physical display, macOS must generate a new virtual monitor.

- **Primary Route (Development Phase)**: Utilize the private, undocumented `CGVirtualDisplay` API within the CoreGraphics framework. This API allows user-space applications to programmatically create virtual displays with custom resolutions and refresh rates without DriverKit entitlements.
  - _Trade-off_: Easy to prototype, does not require special Apple Developer profiles, and works on standard macOS. However, it is undocumented and subject to breakage in future macOS releases.
- **Production Route (Release Phase)**: Implement a user-space driver via Apple's DriverKit framework utilizing the `IOUserFramebuffer` class.
  - _Trade-off_: Robust, officially supported, and stable. However, it requires system-level extension installations and strict developer entitlements from Apple.
- **Fallback Route**: If an extended display is not initially possible, support **Mirror Mode** by using `ScreenCaptureKit` to stream an existing physical display, or direct the user to use a third-party software dummy display (e.g., BetterDisplay) and capture that dummy display.

#### 2.2.2 Video Compression & Encoding

Low-latency transmission requires hardware-accelerated video codecs to avoid CPU bottlenecks.

- **Technology Choice**: H.264 (AVC) encoding via macOS `VideoToolbox` and decoding via Android `MediaCodec`.
- **Rationale**: H.264 is universally supported by the hardware encoders on Apple Silicon and decoders on the Exynos platform. While HEVC (H.265) offers better compression, H.264 decoders typically have lower processing latency and overhead on older/mid-range Android devices like the Tab S6 Lite.
- **Configuration for Latency**:
  - Set `kVTCompressionPropertyKey_RealTime` to `true`.
  - Set GOP (Group of Pictures) structure to omit B-frames (use IPPP structure only) as B-frames introduce encoding delay.
  - Minimize keyframe intervals (I-frames) or use intra-refresh coding if supported.

#### 2.2.3 Network Transport Protocol

Standard protocols like TCP and HTTP are ill-suited for real-time video streaming due to overhead and retransmission delays.

- **Option A: WebRTC**: Standardized real-time communication framework utilizing SRTP over UDP, incorporating SCTP for inputs, ICE for NAT traversal, and Google Congestion Control (GCC) out of the box.
  - _Trade-off_: Handles network jitter, quality adaptation, and security natively. However, building/integrating WebRTC libraries on macOS/Android adds binary weight and complexity.
- **Option B: Custom UDP with ARQ (Selected Recommendation)**: Create a lightweight protocol utilizing raw UDP sockets. Implement packet sequence numbers, chunking for frames larger than MTU (1500 bytes), and Selective Repeat ARQ (Automatic Repeat Request) for lost packets.
  - _Trade-off_: Gives the developer direct, micro-optimized control over packet queuing and immediate frame dropping (e.g. drop old P-frames if a newer frame is already received). It avoids WebRTC's protocol negotiation overhead.
- **USB Channel**: Utilize standard TCP sockets tunneled over USB via `adb reverse` or `adb forward`. Since USB is a highly reliable transport medium, TCP's congestion control will not introduce high latency spikes, simplifying the pipeline for wired configurations.

#### 2.2.4 Input Forwarding & Coordinates Mapping

Forwarding touch events requires coordinate conversion between two active display spaces.

- **Coordinate Translation**:
  Let the tablet viewport resolution be $W_c \times H_c$ and the macOS virtual display resolution be $W_s \times H_s$.
  When a touch down event occurs at client coordinate $(x_c, y_c)$, the client calculates the percentage coordinates:
  $$P_x = \frac{x_c}{W_c}, \quad P_y = \frac{y_c}{H_c}$$
  The server receives $(P_x, P_y)$ and converts it to the native macOS display coordinates:
  $$x_s = P_x \times W_s, \quad y_s = P_y \times H_s$$
- **Event Synthesis on Mac**: Use `CGEventSource` and `CGEventCreateMouseEvent` or `CGEventCreateScrollWheelEvent` to inject mouse down, mouse up, dragging, and scroll events directly into the macOS window server.

---

## 3 Overall Architecture

The TabDisplay system operates as a client-server distributed system. The macOS application acts as the Server (authoritative display and input source), and the Android application acts as the Client (rendering surface and input capturer).

### 3.1 Component Architecture Diagram

```
+-----------------------------------------------------------------------------------+
| macOS SERVER (MacBook Air M2)                                                     |
|                                                                                   |
|  +------------------+      +--------------------+      +-----------------------+  |
|  | Virtual Display  | ---> |  ScreenCaptureKit  | ---> | VideoToolbox Encoder  |  |
|  | (CGVirtualDisplay)|      |   (Raw CVPixelRef) |      | (Hardware H.264/GOP)  |  |
|  +------------------+      +--------------------+      +-----------+-----------+  |
|                                                                    |              |
|  +------------------+      +--------------------+                  | (NAL Units)  |
|  |  CGEvent Injected| <--- |   Input Handler    |                  v              |
|  |  (MouseEvent)    |      | (TCP Command Port) |      +-----------+-----------+  |
|  +------------------+      +--------------------+      |     Network Engine    |  |
|  +------------------+                                  |    (UDP / ADB USB)    |  |
|  | Session Manager  | <==============================> |  - RTP Frame Packetizer|  |
|  | (Bonjour Discovery)|      (Control Link - TCP)      |  - Retransmit Handler |  |
|  +------------------+                                  +-----------+-----------+  |
+--------------------------------------------------------------------|--------------+
                                                                     |
                                                           Network   | (RTP Packets)
                                                           Link      v
+--------------------------------------------------------------------|--------------+
| Android CLIENT (Samsung Tab S6 Lite)                               |              |
|                                                                    v              |
|  +------------------+      +--------------------+      +-----------+-----------+  |
|  |  Render Surface  | <--- | MediaCodec Decoder | <--- |     Network Engine    |  |
|  | (GLSurfaceView)  |      |   (H.264 / Surface)|      |    (UDP / ADB USB)    |  |
|  +------------------+      +--------------------+      |  - Jitter Buffer      |  |
|          |                                             |  - ARQ Requestor      |  |
|          | (Touch/Gesture)                             +-----------------------+  |
|          v                                                                        |
|  +------------------+      +--------------------+                                 |
|  | Input Forwarder  | ---> |   Control Client   | ================================+  |
|  | (MotionEvent)    |      | (TCP Command Port) |                                 |
|  +------------------+      +--------------------+                                 |
+-----------------------------------------------------------------------------------+
```

### 3.2 Data Pipelines

#### 3.2.1 Screen Capture and Processing Pipeline

1. **Virtual Display Creation**: The server uses `CGVirtualDisplay` to allocate a virtual framebuffer in memory. The OS views this as an extended monitor.
2. **GPU Capture**: `ScreenCaptureKit` registers for stream updates on the virtual display. SCK outputs hardware-backed `CVPixelBuffer` frames in `BGRA` or `bi-planar YUV` (4:2:0) format directly from the GPU.
3. **Format Translation**: If needed, the frame is converted to the encoder-supported format (e.g. `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) using `VTPixelTransferSession`.

#### 3.2.2 Video Encoding and Packetization Pipeline

1. **Hardware Encoding**: The `CVPixelBuffer` is sent to `VideoToolbox`. The encoder is configured for H.264, real-time, low-latency rate control (ABR), and zero B-frames.
2. **Elementary Stream Extraction**: The encoder outputs Annex B NAL (Network Abstraction Layer) units.
3. **Packetization**: NAL units are fragmented into RTP-like packets (payload size < 1400 bytes to fit MTU). Each packet contains:
   - Frame Index (uint32)
   - Fragment Index (uint16)
   - Total Fragments (uint16)
   - Presentation Timestamp (PTS)
   - Packet Type (I-Frame, P-Frame, Config/SPS/PPS)

#### 3.2.3 Client Network and Decoding Pipeline

1. **Network Receiver**: Packets are received over UDP/USB. The client places them in a sorted packet buffer.
2. **Jitter Buffering**: A minor queue reorders packets and detects drops. If fragments are missing, the client issues an immediate Nack (Negative Acknowledgment) back to the server.
3. **Frame Assembly**: Once all fragments of a frame are present, it is consolidated into a single NAL unit block.
4. **Hardware Decoding**: The assembled frame is pushed into the `MediaCodec` input queue. `MediaCodec` utilizes hardware decoders to output frames directly to an OpenGL texture surface.
5. **Surface Rendering**: The GPU renders the decoded texture to a `GLSurfaceView` with double-buffering.

#### 3.2.4 Input Feedback Pipeline

1. **Touch Intercept**: The client intercepts `onTouchEvent` on the render view.
2. **Encoding Events**: Touch coordinate ($X, Y$), action type (Down, Up, Move, Scroll), and pointer count are serialized into a lightweight protocol buffer or binary packet.
3. **Transmission**: The event packet is transmitted over a TCP control connection to the macOS server.
4. **macOS Event Injection**: The server maps coordinates to the virtual display's boundaries and uses `CGEventPost` to inject the mouse/click action.

### 3.3 Synchronization

To prevent rendering latency spikes and frame tearing, the clock and frame pacing must be synchronized:

- **Timestamps**: Frames are tagged with monotonic presentation timestamps (PTS) at the time of capture.
- **Frame Pacing**: The client uses these timestamps to gauge rendering intervals. If network congestion causes frames to arrive late, the client drops outdated frames and decodes the latest keyframe to catch up.
- **Clock Drift Compensation**: The server sends its system clock timestamp in periodic control packets. The client computes the latency offset and adjusts the jitter buffer target size dynamically.

### 3.4 Session & Connection Management

The session lifecycle governs discovery, setup, transmission, and teardown:

- **Discovery**: Bonjour/mDNS publishes a service named `_tabdisplay._tcp` from the Mac. The Android app scans for this service.
- **Handshake**: The client connects to the server via TCP Port 5001. The server transmits:
  - Virtual display resolution capabilities.
  - Encoder settings (bitrate, FPS, GOP).
  - Target authentication token.
- **Heartbeat**: A keep-alive ping-pong packet is exchanged every 1 second over TCP. If a heartbeat is missed 3 consecutive times, the session enters recovery mode.
- **Auto-Reconnect**: The client attempts to reconnect to the last known server IP. The server preserves the virtual display session state for 15 seconds, preventing window repositioning on macOS during brief dropouts.

---

## 4 Development Phases

The project is structured into 10 development phases to build stability from the foundation up.

| Phase       | Goal                       | Deliverables                                              | Dependencies | Success Criteria                                                               | Est. Time | Difficulty |
| ----------- | -------------------------- | --------------------------------------------------------- | ------------ | ------------------------------------------------------------------------------ | --------- | ---------- |
| **Phase 0** | Feasibility & Research     | Prototypes of Virtual Display creation and local capture. | None         | Creating a virtual screen on Mac and grabbing its frames via SCK in under 5ms. | 3 Days    | Moderate   |
| **Phase 1** | Project Setup & Frameworks | macOS (Swift) & Android (Kotlin) app skeletons.           | Phase 0      | Clean build of both projects; dependencies (Protobuf) configured.              | 2 Days    | Easy       |
| **Phase 2** | macOS Screen Capture       | Implement high-perf `ScreenCaptureKit` stream loop.       | Phase 1      | Extracting 60 frames/sec as `CVPixelBuffer`s without memory growth.            | 3 Days    | Moderate   |
| **Phase 3** | macOS Video Encoding       | Hardware-accelerated `VideoToolbox` compression.          | Phase 2      | Producing valid H.264 Annex B stream packets from captured frames.             | 4 Days    | Hard       |
| **Phase 4** | Networking & Packetizer    | UDP/USB transport and ARQ packet management.              | Phase 3      | Frame packetizer sending fragments and receiving Nacks over UDP/USB.           | 5 Days    | Hard       |
| **Phase 5** | Android Decoder & Render   | H.264 hardware decoding and screen display.               | Phase 4      | Displaying Mac screen on tablet screen over local network.                     | 5 Days    | Hard       |
| **Phase 6** | Input Forwarding           | Touch & gesture feedback from tablet to Mac.              | Phase 5      | Controlling Mac cursor and clicking windows via Android touch.                 | 4 Days    | Moderate   |
| **Phase 7** | USB Integration            | Automated ADB tunneling and port forwarding.              | Phase 6      | High-speed connection over USB automatically established on plug-in.           | 3 Days    | Moderate   |
| **Phase 8** | Optimization & Congestion  | Latency profiling and adaptive resolution/bitrate.        | Phase 7      | Achieving stable 60 FPS streaming with latency under 40ms over USB.            | 5 Days    | Hard       |
| **Phase 9** | Production Release & UI    | UI/UX styling, installers, logging, and packaging.        | Phase 8      | Completed installer for macOS, APK for Android, clear documentation.           | 4 Days    | Easy       |

---

## 5 Milestones

### Milestone 1: Local Loopback Validation (End of Phase 3)

- **Goal**: Validate the capture and encoding pipeline locally on macOS.
- **Verification**: Capture the virtual display, encode it via VideoToolbox, decode it locally, and render it inside a macOS window.
- **Criteria**: Smooth rendering at 60 FPS, memory footprint under 150MB on Mac, and local pipeline latency under 10ms.

### Milestone 2: Live Remote Mirroring (End of Phase 5)

- **Goal**: Successfully display the macOS desktop on the Android tablet over a network link.
- **Verification**: Connect the Android app over local Wi-Fi, discover the server, establish the session, and stream the macOS desktop.
- **Criteria**: Android tablet renders the live macOS screen with zero blocky artifacts under static conditions. Wireless latency under 100ms.

### Milestone 3: Interactive Extended Monitor (End of Phase 6)

- **Goal**: Establish a functional, interactive secondary display.
- **Verification**: Create a virtual secondary monitor on macOS, stream it to the tablet, and forward touch events.
- **Criteria**: Touch input moves the cursor on the extended display; tapping buttons clicks them; scrolling and dragging actions work natively.

### Milestone 4: Low-Latency USB Pipeline (End of Phase 7)

- **Goal**: Optimize connection performance using a physical wired connection.
- **Verification**: Connect tablet via USB, run the automated ADB tunneling bridge, and stream.
- **Criteria**: End-to-end latency (measured via photodiode or high-speed video) stays consistently under 40ms. Zero frame drops over 15 minutes of testing.

### Milestone 5: Production-Ready Release (End of Phase 9)

- **Goal**: Deliver a polished, self-contained product.
- **Verification**: Distribute the macOS `.app` / `.dmg` installer and the Android `.apk`.
- **Criteria**: Apps install, run, auto-discover, and connect with a clean modern UI. Log reporting operates correctly for troubleshooting.

---

## 6 Engineering Tasks

Here is a breakdown of the specific engineering tasks required to build the TabDisplay pipelines.

### 6.1 Server-Side macOS Tasks

#### Task 6.1.1: Virtual Display Engine implementation

- **Purpose**: Allocate and configure the virtual framebuffer using private APIs.
- **Inputs**: Target resolution width ($W_s$), height ($H_s$), refresh rate (e.g. 60Hz).
- **Outputs**: A valid `CGDisplayID` associated with the new virtual monitor.
- **Dependencies**: None.
- **Completion Criteria**: A new secondary display is visible under **System Settings > Displays**, and its screen bounds are accessible via `NSScreen.screens`.

#### Task 6.1.2: ScreenCaptureKit Frame Capturer

- **Purpose**: Capture raw screen frame buffers from the virtual display.
- **Inputs**: The `CGDisplayID` generated in Task 6.1.1.
- **Outputs**: A continuous stream of `CVPixelBuffer` frames.
- **Dependencies**: Task 6.1.1.
- **Completion Criteria**: Console shows a steady logging of frame arrivals (60 frames per second) with their dimensions and PTS, with CPU consumption of the capture process under 2% of a single M2 core.

#### Task 6.1.3: VideoToolbox H.264 Encoder Wrapper

- **Purpose**: Compress captured pixel buffers into H.264 Annex B streams.
- **Inputs**: `CVPixelBuffer` frames and frame PTS.
- **Outputs**: Sequenced H.264 NAL units (SPS, PPS, Keyframes, Delta frames).
- **Dependencies**: Task 6.1.2.
- **Completion Criteria**: Successfully outputs compressed binary data, where each frame is marked as an I-frame or P-frame. B-frames are verified to be absent.

#### Task 6.1.4: Server UDP Packetizer & ARQ Handler

- **Purpose**: Fragment large video frames into network-safe MTU payloads and dispatch them over UDP.
- **Inputs**: Compressed NAL units from Task 6.1.3.
- **Outputs**: Outbound UDP packets matching MTU size limits, and a retransmit buffer.
- **Dependencies**: Task 6.1.3.
- **Completion Criteria**: Frame fragments are sent with headers (Frame ID, Fragment ID). Retransmits are issued and processed successfully when simulated Nack packets are received.

---

### 6.2 Client-Side Android Tasks

#### Task 6.2.1: Android UDP Network Receiver & Jitter Buffer

- **Purpose**: Receive UDP packet fragments, sort them, and reconstruct video frames.
- **Inputs**: Incoming UDP port stream.
- **Outputs**: Fully assembled frame NAL unit byte arrays.
- **Dependencies**: None.
- **Completion Criteria**: Sorts out-of-order packets and requests retransmissions (Nacks) for missing sequences. Drops frames that exceed the delay threshold.

#### Task 6.2.2: MediaCodec Hardware Decoder Engine

- **Purpose**: Feed reconstructed frame NAL units into the hardware decoder.
- **Inputs**: Assembled H.264 byte arrays from Task 6.2.1.
- **Outputs**: Decoded frame structures passed directly to the renderer surface.
- **Dependencies**: Task 6.2.1.
- **Completion Criteria**: MediaCodec initializes successfully, accepts H.264 input buffers, and outputs decoded frames directly to the designated `SurfaceTexture` without throwing errors.

#### Task 6.2.3: OpenGL ES Surface Render View

- **Purpose**: Display decoded frame textures on the tablet screen with minimal latency.
- **Inputs**: The `SurfaceTexture` populated by MediaCodec.
- **Outputs**: On-screen visual display of the macOS screen.
- **Dependencies**: Task 6.2.2.
- **Completion Criteria**: Low-overhead rendering of the texture to the display buffer, with proper scaling, zero visual tearing, and double-buffering.

---

### 6.3 Bidirectional Interaction Tasks

#### Task 6.3.1: Android Gesture Capturer & Forwarder

- **Purpose**: Capture touch actions on the rendering surface and transmit them to the server.
- **Inputs**: MotionEvent callbacks from the render view.
- **Outputs**: TCP packets containing serialized coordinate percentage and action type.
- **Dependencies**: Task 6.2.3.
- **Completion Criteria**: Instant serializing of Down, Move, Up, and multi-touch gestures. TCP packets are dispatched with latency under 2ms from the physical event.

#### Task 6.3.2: macOS Native Event Injector

- **Purpose**: Parse received event packets and inject them into macOS.
- **Inputs**: TCP event packets from Task 6.3.1.
- **Outputs**: Synthesized CGEvent actions in the macOS Window Server.
- **Dependencies**: Task 6.3.1.
- **Completion Criteria**: Screen coordinate translation maps percent coordinates to virtual screen space, and `CGEventPost` triggers clicks, movements, drag events, and scroll sweeps at the precise target screen points.

---

## 7 Folder Structure

The TabDisplay codebase is organized into macOS, Android, and Shared components to maintain separation of concerns.

```
TabDisplay/
├── android/                        # Android Studio Project (Client App)
│   ├── app/
│   │   ├── build.gradle            # Build configuration and dependencies
│   │   └── src/
│   │       └── main/
│   │           ├── AndroidManifest.xml
│   │           ├── java/com/tabdisplay/client/
│   │           │   ├── MainActivity.kt        # Application Entry Point & Control UI
│   │           │   ├── decoder/
│   │           │   │   └── HardwareDecoder.kt # MediaCodec Wrapper
│   │           │   ├── renderer/
│   │           │   │   └── GlRenderView.kt    # OpenGL Rendering Surface
│   │           │   ├── network/
│   │           │   │   ├── ClientNetwork.kt   # UDP Listener & Jitter Buffer
│   │           │   │   └── ControlClient.kt   # TCP Control Socket Connection
│   │           │   └── input/
│   │           │       └── TouchForwarder.kt  # MotionEvent Interceptor
│   │           └── res/                       # App resources and styling
│   └── build.gradle
├── macos/                          # Xcode Project (Server App)
│   ├── TabDisplayServer/
│   │   ├── TabDisplayServerApp.swift # Application Entry Point
│   │   ├── AppDelegate.swift         # Menu bar lifecycle controller
│   │   ├── DisplayEngine/
│   │   │   ├── VirtualDisplay.swift  # CGVirtualDisplay Private API Wrapper
│   │   │   └── ScreenCapture.swift   # ScreenCaptureKit frame stream controller
│   │   ├── Encoder/
│   │   │   └── VideoEncoder.swift    # VideoToolbox hardware encoder controller
│   │   ├── Network/
│   │   │   ├── ServerNetwork.swift   # UDP Sender & Jitter ARQ Listener
│   │   │   └── ControlServer.swift   # TCP Control Socket Listener & Session Mgr
│   │   └── Input/
│   │       └── EventInjector.swift   # macOS CGEvent synthesis
│   └── TabDisplayServer.xcodeproj
├── shared/                         # Shared Protocols and Configurations
│   ├── proto/
│   │   └── events.proto              # Protobuf definitions for Input & Control
│   └── compile_proto.sh              # Utility script to compile proto to Swift/Kotlin
├── scripts/                        # Utility & Development helper scripts
│   ├── setup_usb_tunnel.sh           # Script automating adb forward tcp configurations
│   └── latency_tool.py               # Latency profiling helper tool
└── README.md                       # High-level architecture and build instructions
```

---

## 8 Technology Stack

### 8.1 Core Platform Languages

- **macOS Server**: **Swift 5+**
  - _Rationale_: Swift is Apple's native systems language. It provides direct C interoperability with CoreGraphics, ScreenCaptureKit, and VideoToolbox without bridging overhead, ensuring high performance.
- **Android Client**: **Kotlin**
  - _Rationale_: Kotlin is the modern standard for Android development. It compiles to optimized bytecode, simplifies asynchronous threading via Coroutines, and interfaces directly with Android’s `MediaCodec` and native graphics layers.

### 8.2 Capture & Compression Technologies

- **Capture Engine**: **ScreenCaptureKit (macOS 12.3+)**
  - _Rationale_: Designed by Apple specifically for low-latency desktop capture. It accesses GPU-backed pixel buffers (`CVPixelBuffer`) directly, avoiding expensive copy operations from GPU to CPU memory.
- **Encoding / Decoding Codec**: **H.264 (AVC) / Profile: Baseline**
  - _Rationale_: Hardware-accelerated H.264 encoders and decoders are universally present in M-series Macs (`VideoToolbox`) and Android devices (`MediaCodec`). Baseline profile is chosen because it avoids B-frames, eliminating the frame-reordering latency (minimum 1 frame delay) inherent in Main/High profiles.

### 8.3 Network Protocols & Libraries

- **Control / Input Channel**: **TCP Socket over Custom Protocol (Protobuf)**
  - _Rationale_: Control commands (handshake, resolution changes) and user inputs (clicks, key presses) require absolute reliability. TCP guarantees packet delivery, and Protocol Buffers (Protobuf) provide clean, cross-platform serialization with minimal payload overhead.
- **Video Stream Channel**: **Custom UDP Socket with Selective Repeat ARQ**
  - _Rationale_: Real-time video cannot tolerate the head-of-line blocking delay of TCP. UDP delivers packets immediately. A custom lightweight ARQ (Automatic Repeat Request) system ensures that if a packet drop occurs, the client requests _only_ the missing packet of the current frame, dropping the frame entirely if its delivery time exceeds 16ms.

### 8.4 Discovery & USB Integration

- **Service Discovery**: **Bonjour (mDNS / DNS-SD)**
  - _Rationale_: Apple's native network configuration framework. Supported out of the box in macOS (`NSNetService`) and Android (`NsdManager`). Allows zero-configuration discovery on local Wi-Fi links.
- **Wired Connection**: **ADB (Android Debug Bridge) Port Forwarding**
  - _Rationale_: Utilizing ADB port forwarding (`adb forward tcp:5001 tcp:5001`) lets the system route TCP/UDP packets through a physical USB cable using standard developer options. This avoids the need to implement custom Android USB Accessory drivers or require root privileges, while delivering the lowest latency and highest reliability.

---

## 9 Development Order

To ensure a structured, testable, and robust development lifecycle, features must be implemented in a strict bottom-up sequence. No component should be built until its underlying APIs have been validated.

```
                  [ Phase 9: UI Polish & Production DMG/APK ]
                                      ▲
                     [ Phase 8: Adaptive Bitrate & Profiling ]
                                      ▲
                    [ Phase 7: USB Tunneling & ADB Integration ]
                                      ▲
                    [ Phase 6: Android Touch & macOS Injection ]
                                      ▲
                    [ Phase 5: Android MediaCodec & OpenGL ES ]
                                      ▲
                   [ Phase 4: UDP Network Stack & ARQ Packetizer ]
                                      ▲
                     [ Phase 3: VideoToolbox H.264 Encoder ]
                                      ▲
                     [ Phase 2: ScreenCaptureKit Capture ]
                                      ▲
                  [ Phase 1: Project Skeleton & Shared Protos ]
                                      ▲
                     [ Phase 0: CGVirtualDisplay Research ]
```

### 9.1 Step-by-Step Implementation Sequence

1. **Phase 0 (Research)**: Create standalone command-line scripts to verify `CGVirtualDisplay` creation and ensure frames can be extracted locally.

   #### Research Matrix

   | Research Question                                  | Answer                        | Details / Validation                                                                                                                                 |
   | :------------------------------------------------- | :---------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------- |
   | **Can ScreenCaptureKit capture CGVirtualDisplay?** | **YES**                       | ScreenCaptureKit detects virtual displays natively, listing their `CGDirectDisplayID` inside `SCShareableContent` for targeting.                     |
   | **Can CGVirtualDisplay survive reboot?**           | **NO**                        | The display is dynamic and bound to the lifecycle of the host process's active `CGVirtualDisplay` object. It is cleanly deallocated on process exit. |
   | **Can apps render onto it?**                       | **YES**                       | macOS recognizes it as an independent display surface, permitting full application rendering and window positioning.                                 |
   | **Can Mission Control see it?**                    | **YES**                       | It integrates natively with the macOS display manager, appearing in Mission Control and Display Arrangements in System Settings.                     |
   | **Can windows be moved?**                          | **YES**                       | Standard window movement and layout APIs work natively on the virtual display coordinates.                                                           |
   | **Does it require SIP disabled?**                  | **NO**                        | Verified on Apple Silicon (M2) macOS. Works in standard user space without changing system integrity configurations.                                 |
   | **Does it survive Sonoma updates?**                | **YES**                       | Tested and verified on macOS 14 (Sonoma) and later versions (macOS 15/16).                                                                           |
   | **Can it ship?**                                   | **YES (Direct Distribution)** | Cannot be published to the Mac App Store due to undocumented CoreGraphics API usage, but fully deployable via signed Developer ID DMG packages.      |

2. **Phase 1 (Setup)**: Initialize Xcode and Android Studio projects. Compile the shared Protobuf contract into Swift and Kotlin classes.
3. **Phase 2 (Capture)**: Implement the screen capture class on macOS, feeding frames to a dummy collector to verify 60fps throughput.
4. **Phase 3 (Encode)**: Implement the H.264 encoder on macOS. Verify NAL extraction by writing the encoded stream locally to an `.h264` file and checking playback in VLC player.
5. **Phase 4 (Network)**: Set up the UDP socket classes on Mac and Android. Verify that fragments are packetized, transmitted, and reassembled accurately using test payloads.
6. **Phase 5 (Decode & Render)**: Integrate MediaCodec and OpenGL on Android. Connect to the macOS encoder stream over UDP and verify mirroring.
7. **Phase 6 (Interaction)**: Add touch event interception to the Android surface and event injection to macOS. Verify mouse coordinates line up.
8. **Phase 7 (USB)**: Implement the ADB connection manager, replacing the UDP socket wrapper with TCP tunneled sockets over a USB cable.
9. **Phase 8 (Optimization)**: Profile latency, implement dynamic bitrate adjustments based on client packet drop reports, and optimize thread priorities.
10. **Phase 9 (Release)**: Polish UI layouts, add logging/diagnostics, and package the final builds.

---

## 10 Testing Strategy

We treat testing as a primary design requirement. TabDisplay utilizes a three-tier testing framework to ensure low latency, crash-free operation, and recovery from connection interruptions.

### 10.1 Automated Unit & Integration Testing

#### 10.1.1 Unit Tests

- **macOS (XCTest)**:
  - Test packetizer fragmentation: Ensure frames larger than MTU are divided correctly and that the reconstructed NAL unit matches the original byte-for-byte.
  - Test input mapping: Verify that percentage coordinate objects $(0.5, 0.5)$ map to precise virtual screen pixels depending on custom display aspect ratios.
- **Android (JUnit)**:
  - Test jitter buffer reordering: Feed out-of-order packets into the jitter buffer queue and verify that output frames are sorted sequentially.
  - Test Nack request generator: Feed frame fragments with missing indices and confirm that the client emits correct packet range retransmission requests.

#### 10.1.2 Integration Tests

- **Session Lifecycle**: Simulate network drops to confirm the server preserves display configurations and that the client successfully negotiates session recovery upon reconnection.
- **Stream Flow Control**: Verify that resolution adjustments trigger real-time changes in both the VideoToolbox encoder configuration and Android MediaCodec configuration without terminating the active connection.

### 10.2 Real-time Latency & Performance Testing

```
+-------------------------------------------------------------------+
|                  End-to-End Latency Measurement                   |
|                                                                   |
|  +--------------------+                         +--------------+  |
|  | macOS Main Display |                         | Android Tab  |  |
|  |                    |                         |              |  |
|  |   [00:01:23.450]   |                         | [00:01:23.490]  |
|  +---------+----------+                         +------+-------+  |
|            |                                           |          |
|            +-------------------+                       |          |
|                                v                       v          |
|                        +--------------------------------+         |
|                        | High-Speed Camera (240 FPS)    |         |
|                        +--------------------------------+         |
+-------------------------------------------------------------------+
```

- **Latency Measurement Protocol**: Run a millisecond-precision stopwatch application on the macOS virtual screen and stream it. Use a high-speed camera (240 FPS) to capture both the virtual screen mirrored in a window on the Mac and the physical Android tablet screen side-by-side.
  $$\text{End-to-End Latency} = T_{\text{Camera\_Mac}} - T_{\text{Camera\_Android}}$$
  Verify that latency remains under 40ms over USB and under 80ms over local Wi-Fi.
- **Resource Leak Detection**: Run the streaming session continuously for 4 hours.
  - _Mac_: Profile memory with Xcode Instruments to ensure `CVPixelBuffer` frames are released and no memory leaks occur in the ScreenCaptureKit loop.
  - _Android_: Monitor Android Profiler to verify garbage collection pauses stay below 3ms and that memory usage is stable.

### 10.3 Failure Mode Injection Testing

- **Simulated Network Degradation**: Use network simulation tools (e.g., Network Link Conditioner on macOS) to inject packet loss (up to 15%) and jitter (up to 30ms). Verify that the ARQ protocol recovers frames and that the video stream degrades gracefully without crashing.
- **Physical Interruption**: Unplug the USB cable during active streaming. Verify that the Android app pauses rendering, shows a reconnection prompt, and resumes immediately when the cable is plugged back in.

---

## 11 Optimization Plan

To deliver a high-fps, near-zero lag secondary display, we focus optimizations on memory copy elimination and adaptive networking.

### 11.1 Zero-Copy Data Pipeline

Every CPU memory copy adds processing overhead and increases latency.

- **macOS Server**: Configure ScreenCaptureKit to write directly to Apple Silicon's unified memory. VideoToolbox reads this GPU-backed buffer (`CVPixelBuffer`) directly. This ensures zero CPU-to-GPU memory copies during the capture-to-encode path.
- **Android Client**: Configure MediaCodec to decode directly to an OpenGL texture surface (`SurfaceTexture`). By using native hardware surfaces, decoded frames go directly from the GPU video processing unit to the display frame buffer, eliminating CPU pixel copying.

### 11.2 Threading & Core Affinity Strategy

To prevent thread starvation and coordinate pipelines smoothly, operations run on isolated threads:

- **Mac App**:
  - Capture stream callback runs on a dedicated Grand Central Dispatch (GCD) serial queue.
  - Encoder operations run on a high-priority background thread.
  - UDP packet transmission uses async socket dispatch to prevent blocking the encoder thread.
- **Android App**:
  - Main Thread: Manages UI, status overlays, and input callbacks.
  - Network Thread: Blocks on UDP socket reads, placing packets into the Jitter Buffer.
  - Decoder Thread: Polling loop feeding MediaCodec input buffers and releasing output buffers.
  - OpenGL Render Thread: GlSurfaceView thread rendering frames at 60 FPS.

### 11.3 Adaptive Bitrate Control (ABR)

To handle changing Wi-Fi signal conditions:

1. **Telemetry**: The client monitors frame arrival metrics and counts dropped frames.
2. **Feedback**: Every 500ms, the client transmits an RTCP-like telemetry packet containing:
   - Packet Loss Rate
   - Average Jitter (ms)
   - Current Latency (ms)
3. **Adjustment**: The server parses telemetry. If packet loss exceeds 2%, the server reduces the VideoToolbox target bitrate. If packet loss drops below 0.5% and latency is low, the server increases the bitrate incrementally to restore image crispness.
4. **Resolution Scaling**: If the network throughput degrades severely, the server drops capture resolution to $0.75 \times$ native resolution, maintaining 60 FPS at the expense of temporary text sharpness.

---

## 12 Risks

The following matrix identifies the primary technical risks and provides mitigations and fallback paths.

| Risk Description                                                                                           | Likelihood | Impact | Mitigation Plan                                                                                     | Fallback Plan                                                                                                                                     |
| ---------------------------------------------------------------------------------------------------------- | ---------- | ------ | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Private API Deprecation**: Apple removes or breaks the private `CGVirtualDisplay` API in a macOS update. | Medium     | High   | Encapsulate virtual display configuration inside a clean `DisplayProvider` interface.               | Transition to Apple's official `DriverKit` framework (`IOUserFramebuffer`) or utilize third-party dummy monitors (e.g. BetterDisplay) as sources. |
| **Exynos Thermal Throttling**: The Samsung Tab S6 Lite processor heats up, causing frame drops.            | High       | Medium | Use H.264 Baseline Profile to minimize decoding CPU overhead; ensure zero-copy surface rendering.   | Dynamically scale stream down to 30 FPS or reduce resolution to $1200 \times 800$ when throttling is detected.                                    |
| **Network Jitter / Congestion**: Wireless interference causes packets to drop, spiking latency.            | High       | High   | Implement UDP transport with a lightweight Selective Repeat ARQ system and custom telemetry loops.  | Prompt user to switch to wired USB connection; automatically lower bitrate to maintain target FPS.                                                |
| **App Store Rejection**: macOS app rejected due to private API usage.                                      | High       | Medium | Target self-distribution (Developer ID signing, direct DMG download) rather than the Mac App Store. | Bypasses App Store rules entirely by distributing the macOS app via GitHub or a custom website.                                                   |

---

## 13 Future Features (Version 2)

To keep the initial development scope focused on latency and stability, the following features are deferred:

- **Multi-Tablet Display**: Streaming to multiple tablets simultaneously.
- **Audio Forwarding**: Capturing macOS system audio and streaming it to the tablet speakers.
- **Clipboard Sharing**: Synchronizing copy-paste buffers between macOS and Android.
- **Secure Transport Encryption**: Wrapping the UDP video stream in DTLS/SRTP for secure remote streaming over public networks.
- **Reverse HID Input**: Forwarding Bluetooth keyboards or mice plugged physically into the Android tablet back to macOS.

---

## 14 Definition of Done

Each phase and the final deliverable are considered complete only when they meet these criteria:

- **Compilation**: Clean compilation on both Xcode and Gradle with zero warnings treated as errors.
- **Latency Profile**: End-to-end latency measures:
  - **Sub-40ms** over USB (Wired ADB mode).
  - **Sub-80ms** over Wi-Fi (under standard 5GHz home router conditions).
- **Zero Resource Leaks**: Memory consumption remains flat (fluctuating less than 10MB) over 2 hours of continuous mirroring.
- **Frame Pacing**: 60 FPS is maintained for 30 minutes with less than 5 frame drops in stable network conditions.
- **Resiliency**: Reconnection completes automatically in under 3 seconds after simulating a temporary network dropout.

---

## 15 Development Rules

To maintain codebase integrity, all contributors must adhere to these architectural rules:

1. **Platform Isolation**: macOS Swift code and Android Kotlin code must remain strictly separated within their respective folders. No platform-specific framework dependencies are permitted in the `/shared` folder.
2. **API-First Contracts**: Any changes to data flow or message structures must be updated in `shared/proto/events.proto` first, compiled, and then integrated.
3. **No Thread Blocking**: The main UI execution path must never block on network operations, video encoding, decoding, or frame assembly.
4. **Clean Abstractions**: Hardware interfaces (VideoToolbox, MediaCodec) must be wrapped in generic classes so they can be replaced if alternative codecs (AV1, VP9) are introduced.
5. **No Placeholders**: Do not check in placeholder code, temporary mocks, or empty function blocks to git. Every commit must be fully compilable and functional.
