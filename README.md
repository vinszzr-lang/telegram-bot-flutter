# Excellent Mirror — Remote Pterodactyl build

USB/ADB transport has been removed. The Flutter/Android build workflow itself is unchanged, including `flutter build apk --release --split-per-abi`.

The APK:
1. asks for Android screen-capture permission;
2. fetches `server.json` from the specified GitHub repository;
3. connects directly to the configured host over WebSocket;
4. sends the existing H.264 packets to the Node.js server;
5. if the connection times out/disconnects, refreshes `server.json` and retries.

The `server/` folder is a Node.js service intended to run in a Pterodactyl Node.js server. It also includes a browser WebCodecs viewer so the old Chromebook-local viewer is no longer required.

The current GitHub configuration is:
https://raw.githubusercontent.com/vinszzr-lang/Project-Reskin-Gue/main/server.json
