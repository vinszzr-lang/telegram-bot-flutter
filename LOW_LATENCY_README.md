# Excellent Mirror — Low Latency Full Rebuild

Architecture: Android MediaProjection → hardware H.264 → USB ADB reverse → Chromebook localhost → WebSocket → WebCodecs.

The transport uses ordered TCP and carries a presentation timestamp with every encoded frame. The browser keeps only a tiny decoder queue and, if it falls behind, discards whole old GOPs at an IDR boundary rather than dropping arbitrary H.264 delta frames. This prevents green/reference corruption while avoiding seconds of latency.

Rotation keeps the TCP connection alive. The encoder is rebuilt only after a debounced display-size change, then a fresh SPS/PPS and IDR are sent.

Recommended for low-end Chromebook:
- 540p / 30 FPS / 2–3 Mbps for the lightest load.
- 720p / 30 FPS / 3–4 Mbps for a balance.
- 60 FPS is available but requires more decoder/CPU/GPU headroom.

USB: run the Chromebook server, connect the phone with USB debugging enabled, then open http://localhost:3000.
