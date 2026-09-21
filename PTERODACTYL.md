# ChatWithU + Pterodactyl

## 1. Backend Node.js
Upload the `server/` folder to a Pterodactyl Node.js server.

Recommended:
- Node.js 20+
- Startup command: `npm install --omit=dev && node index.js`
- Environment: `PORT` should match the allocated server port.
- For the requested endpoint, use `PORT=5201` **only if Pterodactyl has allocated/exposed port 5201 to this server**.
- `PUBLIC_BASE_URL=http://panelbaru2.rexzystr.my.id:5201`
- Set a long random `JWT_SECRET`.

The backend binds to `0.0.0.0` so Pterodactyl can expose it through its allocation.

## 2. Important Pterodactyl detail
`panelbaru2.rexzystr.my.id:5201` must route to the **Node.js server allocation**, not merely to the Pterodactyl panel itself. If `:5201` is currently the panel's port, create/assign a separate allocation for the ChatWithU server and use that public host:port in `PUBLIC_BASE_URL` and the Flutter `CHATWITHU_BASE_URL`.

## 3. Flutter APK
The default API endpoint is already:

`http://panelbaru2.rexzystr.my.id:5201`

Build with:

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=CHATWITHU_BASE_URL=http://panelbaru2.rexzystr.my.id:5201
```

If your Pterodactyl allocation uses another host/port, change the dart-define value.

## Included server features
- Register/login/JWT
- Contacts with a separate saved contact name
- Realtime Socket.IO messages
- Typing indicator events
- Read status
- Image/video/file uploads
- Profile avatar uploads
- Per-user clear-chat history
- In-chat search
- Media/document/link index
- Verified badge/profile state
- Basic banned-account enforcement
- JSON persistence (no native database dependency)

This JSON backend is intended for a small/self-hosted deployment. For a large production service, move persistence to PostgreSQL/MySQL and put the API behind HTTPS.
