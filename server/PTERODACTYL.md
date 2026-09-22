# Pterodactyl Setup • ChatWithU Server V4

## 1. Server

Create a Node.js server/container using Node **20+**.

Allocate:

```text
2667
```

## 2. Environment

```text
PORT=2667
PUBLIC_BASE_URL=http://YOUR-DOMAIN:2667
JWT_SECRET=<random secret 32+ chars>
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin
```

`ADMIN_PASSWORD` is the initial/bootstrap credential. This build defaults to `admin` if the Pterodactyl variable is missing. Once inside `/admin`, you can change the admin password from **Settings → Admin password**. The changed password is stored as a bcrypt hash in `data/db.json`.

## 3. Startup

```bash
npm install --omit=dev && node index.js
```

## 4. Check

```text
http://YOUR-DOMAIN:2667/health
```

Expected:

```json
{"ok":true}
```

## 5. Admin

Open:

```text
http://YOUR-DOMAIN:2667/admin
```

The dashboard includes:

- Overview / server pulse
- Full user list
- User detail editor
- Verified toggle
- Banned toggle
- Built-in and custom badge controls
- User password reset
- Message moderation
- Activity/audit log
- Server settings
- Admin password change

## 6. Persistence

Keep these paths persistent if your Pterodactyl setup recreates containers:

```text
data/db.json
uploads/avatars/
uploads/media/
```

For production, back up `data/db.json` regularly.
