# Excellent Mirror — ROTATIONFIX

Fixes Android portrait/landscape rotation without treating the temporary MediaCodec swap as an ADB/TCP disconnect.

Changes:
- Debounces Android display-change callbacks for 350 ms.
- Serializes encoder/VirtualDisplay rebuilds through the existing pipeline lock.
- Keeps the TCP socket alive while the encoder is being recreated.
- Ignores the expected MediaCodec IllegalStateException during the rotation swap instead of reconnecting the stream.
- Requests a keyframe after the new encoder starts.
- Cancels pending rotation rebuilds when the service stops.

Use this Android project together with the existing SMOOTHFIX Chromebook server.
