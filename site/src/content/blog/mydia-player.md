---
title: "Introducing Mydia Player"
date: 2026-02-22
summary: "A cross-platform media player with peer-to-peer remote access, offline downloads, and hardware-accelerated playback on Android, iOS, macOS, and web."
tags: ["release", "player"]
---

Mydia now ships a cross-platform player built with Flutter and a shared Rust networking core. It uses mpv for native playback, [iroh](https://www.iroh.computer/) for peer-to-peer remote connections without port forwarding, and supports offline downloads. Builds are available for Android (APK), iOS (TestFlight), macOS, and the web. [Download the latest release](https://github.com/getmydia/mydia/releases/latest).

## Cross-platform support

The native apps use mpv via a Flutter binding for hardware-accelerated playback across common video codecs and container formats. The web build embedded in Mydia Server at `/player` uses server-side ffmpeg transcoding when the browser cannot play a stream directly.

Primary development targets are **Android**, **iOS**, and **macOS**, with Windows and Linux builds also published on each release:

- **Android**: APK included in each [GitHub release](https://github.com/getmydia/mydia/releases/latest)
- **iOS**: Distributed through TestFlight
- **Web**: Served by Mydia Server at `/player`

## Remote Access

The player can connect to a Mydia Server instance directly by URL or through **Remote Access**, a peer-to-peer layer built on [iroh](https://www.iroh.computer/). Remote Access establishes encrypted QUIC connections without exposing the server port to the public internet, using a short claim code during initial pairing to exchange the server's node ID.

Remote Access is off by default and requires enabling both the server environment variable and the setting in the web UI.

Running the container with `network_mode: host` (or forwarding the UDP port) improves the chance of a direct peer-to-peer connection. When NAT traversal cannot establish a direct path, traffic falls back to a relay server. The default public relay is bandwidth-throttled, and the relay server itself is open source if you want to self-host one.

### Why iroh

Remote Access went through a few prototypes before settling on iroh:

1. A custom UDP protocol using the Noise framework for encryption worked on direct links, but required manual port configuration and left NAT traversal to us.
2. WebRTC did not fit a standalone non-browser client and server model well.
3. libp2p had the necessary primitives, but added more protocol surface than we needed.
4. A standalone DHT prototype had slow initial node discovery.

iroh provides QUIC transport, UDP hole punching, DNS/pkarr node discovery, and relay fallback in one library.

### Architecture

The networking stack lives in a shared Rust crate (`mydia_p2p_core`) used by both the server and the player. Mydia Server calls it through a Rustler NIF, and Mydia Player calls the same crate through `flutter_rust_bridge`, keeping protocol behavior identical on both ends.

## Offline Downloads

Movies and episodes can be downloaded to a device for offline playback. You can also attach downloads to Mydia's **Collections** to keep a set of titles synced across devices.

## Current status

The player is in early development and has not been tested against every combination of platform, codec, and network setup. If you run into a bug, please [open a GitHub issue](https://github.com/getmydia/mydia/issues).
