# Excellent Mirror Node.js server

This is the remote replacement for the old USB/ADB Chromebook transport.

## Pterodactyl setup

Create a normal **Node.js** server in Pterodactyl and allocate the TCP port you want to expose (example: `2044`).

Upload:
- `package.json`
- `index.js`
- `public/index.html`

Startup command:
```bash
npm install --omit=dev && npm start
```

If Pterodactyl gives the process a different primary port, set `SERVER_PORT` to that allocation.

## Endpoints

- `GET /` or `GET /viewer` — WebCodecs mirror viewer.
- `GET /health` — JSON health/status.
- `WS /ws?role=sender` — Android sender.
- `WS /ws?role=viewer` — browser viewer.

The APK does **not** contain the Pterodactyl hostname as a permanent server address. It fetches:

`https://raw.githubusercontent.com/vinszzr-lang/Project-Reskin-Gue/main/server.json`

and uses its `server` value. If the remote server times out or disconnects, it refreshes that file and retries.

Example `server.json`:
```json
{
  "server": "http://your-domain.example:2044"
}
```
