TabDisplay — System Architecture & Engineering Problem Definition

Purpose

This document defines the technical architecture of TabDisplay and identifies the real engineering challenges.

This is not a feature list.

This is a technical specification describing what the software actually needs to accomplish internally.

⸻

Project Objective

TabDisplay is a distributed real-time display system.

It consists of two independent applications working together as one system.

The goal is to transform an Android tablet into a high-performance external display for macOS with minimal latency while maintaining excellent image quality and responsiveness.

The software should feel as close as possible to a physical monitor.

⸻

High-Level Architecture

                    TabDisplay System
                ┌─────────────────────────┐
                │      macOS Server       │
                │                         │
                │ Screen Capture          │
                │ Video Encoding          │
                │ Input Receiver          │
                │ Session Manager         │
                │ Network Stack           │
                └──────────┬──────────────┘
                           │
                WiFi / USB │
                           │
                ┌──────────▼──────────────┐
                │     Android Client      │
                │                         │
                │ Network Receiver        │
                │ Video Decoder           │
                │ Renderer                │
                │ Touch Handler           │
                │ Input Sender            │
                └─────────────────────────┘

The Mac acts as the authoritative display source.

The Android tablet is a remote rendering device.

⸻

Primary Engineering Pipeline

The system consists of five major pipelines:

1. Screen Capture
2. Video Processing
3. Network Transport
4. Rendering
5. Input Feedback

Each pipeline must operate continuously and independently while remaining synchronized.

⸻

Screen Capture Pipeline

Goal:

Acquire desktop frames from macOS efficiently.

Responsibilities:

- Capture selected display
- Capture windows
- Capture cursor
- Handle resolution changes
- Handle refresh-rate changes
- Minimize capture overhead

Questions to solve:

How frequently should frames be captured?

Should duplicate frames be discarded?

How are damaged regions detected?

Can partial updates reduce bandwidth?

⸻

Video Processing Pipeline

Goal:

Convert captured frames into compressed video with minimal latency.

Responsibilities:

- Hardware encoding
- Resolution scaling
- Frame pacing
- Color conversion
- Bitrate control

Challenges:

Compression introduces delay.

Higher quality increases latency.

Lower bitrate reduces image quality.

Finding the optimal balance is a core engineering problem.

⸻

Network Pipeline

Goal:

Transport frames as quickly and reliably as possible.

Responsibilities:

- Session establishment
- Packet ordering
- Packet loss recovery
- Congestion handling
- Adaptive bitrate
- Keep-alive
- Reconnection

Questions:

Should transport use:

TCP?

UDP?

QUIC?

WebRTC?

Each choice affects latency, reliability, implementation complexity, and future extensibility.

⸻

Rendering Pipeline

Goal:

Display incoming frames immediately.

Responsibilities:

Decode video

Synchronize rendering

Maintain frame timing

Avoid tearing

Recover after dropped frames

Maintain smooth animation

The renderer must never become the bottleneck.

⸻

Input Pipeline

Goal:

Allow the tablet to behave as an interactive extension of the Mac.

Responsibilities:

Touch events

Mouse events

Keyboard events

Scroll events

Gesture recognition

Coordinate translation

Latency compensation

Input must feel immediate.

⸻

System Synchronization

This is one of the hardest engineering problems.

The following components operate asynchronously:

Capture

Encoding

Transmission

Decoding

Rendering

Input

They must remain synchronized despite:

Variable network latency

Dropped packets

Frame loss

Resolution changes

Network interruptions

Clock drift

⸻

Session Management

Responsibilities:

Device discovery

Authentication

Handshake

Capability negotiation

Reconnect

Error recovery

Heartbeat

Graceful disconnect

The connection should survive temporary network instability whenever possible.

⸻

True Engineering Bottlenecks

Many parts of this project are straightforward.

The following are not.

⸻

Bottleneck 1

Creating a True Secondary Display

This is the largest architectural challenge.

macOS does not generally allow user-space applications to create arbitrary virtual displays.

Questions:

Can Apple’s APIs expose a usable virtual display?

Will additional drivers be required?

Should the application initially support only mirroring?

Should “extended display” become a later milestone?

This problem must be researched before implementation.

⸻

Bottleneck 2

End-to-End Latency

Latency accumulates across the pipeline:

Screen Capture

↓

Encoding

↓

Network

↓

Decoding

↓

Rendering

↓

Touch Feedback

Even small delays add up.

Measure latency at each stage independently.

Optimization should target the slowest stage rather than guessing.

⸻

Bottleneck 3

Hardware Acceleration

Hardware encoders and decoders differ across platforms.

The software should abstract codec implementation behind clear interfaces so alternative implementations can be swapped without affecting higher layers.

⸻

Bottleneck 4

Network Variability

Wi-Fi conditions constantly change.

Bandwidth

Interference

Packet loss

Jitter

The software must adapt dynamically.

The goal is graceful degradation rather than failure.

⸻

Bottleneck 5

Input Responsiveness

Touch input feels broken if latency exceeds user expectations.

Mouse movement must remain smooth.

Coordinate mapping must remain accurate under scaling and rotation.

⸻

Bottleneck 6

Synchronization

Capture and rendering occur on different devices with different clocks.

Frame timestamps should be authoritative.

The renderer should compensate for timing differences without introducing visible lag.

⸻

Bottleneck 7

Resource Usage

Target constraints:

Minimal CPU

Minimal GPU overhead

Minimal battery usage

Stable memory consumption

Efficient threading

The software should perform well even during prolonged use.

⸻

Architectural Principles

The project should be divided into independent modules.

Suggested modules include:

Capture Engine

Encoding Engine

Network Engine

Protocol Layer

Session Manager

Decoder

Renderer

Input Manager

Configuration Manager

Logging System

Telemetry System

Testing Framework

Each module should expose clear interfaces and hide implementation details.

⸻

Threading Strategy

Avoid a single main execution path.

Independent responsibilities should run independently.

Example:

Capture Thread

Encoder Thread

Network Thread

Decoder Thread

Renderer Thread

Input Thread

Session Thread

Blocking operations must never stall the rendering pipeline.

⸻

Scalability

The architecture should support future expansion without major redesign.

Potential future capabilities include:

Multiple tablets

Multiple monitors

Linux support

Windows support

Remote streaming

Cloud relay

USB optimization

HDR

120 FPS

High-DPI rendering

The architecture should anticipate these features even if they are not implemented initially.

⸻

Success Metrics

The project succeeds when:

The connection is stable.

Rendering is smooth.

Input feels immediate.

The codebase remains modular.

Every subsystem is independently testable.

The architecture supports future growth without requiring significant rewrites.

Every engineering decision should move the project closer to these goals.
