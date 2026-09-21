# ChatWithU Server • Admin Command Center V4

Node.js + Express + Socket.IO backend for ChatWithU, prepared for Pterodactyl on port **5201**.

## Features

- JWT user authentication
- Register / login / profile / username
- Contacts and chat
- Realtime Socket.IO messages, typing, presence and read status
- Image/video/file uploads
- Full admin dashboard at `/admin`
- User search and full non-sensitive profile data
- Verified ON/OFF
- Banned ON/OFF
- Built-in + custom badges
- User password reset
- Message moderation
- Activity/audit log
- Registration and maintenance controls
- Upload limit setting
- **Admin password change directly from the website**
- Passwords stored as bcrypt hashes when changed from the dashboard
- Animated glassmorphism admin UI with responsive mobile layout

## Pterodactyl

Environment:

```env
PORT=5201
PUBLIC_BASE_URL=http://YOUR-DOMAIN:5201
JWT_SECRET=USE-A-LONG-RANDOM-SECRET-AT-LEAST-32-CHARS
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin
```

Startup command:

```bash
npm install --omit=dev && node index.js
```

Health:

```text
http://YOUR-DOMAIN:5201/health
```

Admin:

```text
http://YOUR-DOMAIN:5201/admin
```

### Admin password flow

The first admin login uses `ADMIN_USERNAME` + `ADMIN_PASSWORD`. If Pterodactyl does not provide `ADMIN_PASSWORD`, this build defaults to `admin`.

After logging in:

```text
Admin → Settings → Admin password
```

Enter the current password and a new password (minimum 8 characters). The new password is saved as a **bcrypt hash** in `data/db.json`, so the website becomes the normal place to change it. Keep the Pterodactyl `ADMIN_PASSWORD` as an emergency/bootstrap fallback if the admin record is removed.

## Important

- Do not expose the server publicly with `JWT_SECRET=CHANGE_ME_NOW`.
- Use HTTPS/reverse proxy for production.
- Do not publish `data/db.json` or the `uploads/` directory as source code.
- Admin dashboard intentionally never displays user password or password hash.
