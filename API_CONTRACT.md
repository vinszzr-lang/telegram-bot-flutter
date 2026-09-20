# ChatWithU API Contract

Base URL: `https://stock-staining-composure.ngrok-free.dev`

## User auth
- `POST /api/auth/register` body `{firstName,lastName,username,password}` -> `{token,user}`
- `POST /api/auth/login` body `{username,password}` -> `{token,user}`
- `GET /api/auth/me` -> `{user}`
- `PATCH /api/auth/username` body `{username}` -> `{token,user}`. Username is globally unique. Server rewrites contacts/messages to the new username so chat history is retained.
- `POST /api/profile/avatar` multipart field `file` -> `{user}`. Image only, max 10 MB.

## Contacts
- `GET /api/contacts`
- `GET /api/inbox`
- `POST /api/contacts` body `{username,name}`. Returns 409 if that contact is already saved.
- `PATCH /api/contacts/:username` body `{name}`
- `DELETE /api/contacts/:username`

## Fast sync / real-time fallback
- `GET /api/sync` -> `{user,contacts,inbox,serverTime}`.
- The Android client uses Socket.IO as the primary instant channel and a 400 ms fallback sync heartbeat (about 2.5 requests/second) so changes from the admin website are reflected without manual refresh.

## Chats
- `GET /api/chats/:username/messages?since=<ISO timestamp>`
- `POST /api/chats/:username/messages` body `{type:"text",message}`
- `POST /api/chats/:username/media` multipart `file` + `type=image|video`; max 50 MiB

Message shape:
`{id,type,message,url,mediaUrl,senderUsername,recipientUsername,status,createdAt,updatedAt}`

Statuses: `sending`, `sent`, `delivered`, `read`, `failed`.

## Socket.IO
Handshake: `auth.token`.

Server -> client:
- `message`
- `profile_updated` (including username/verified/avatar changes)
- `banned`
- `message_deleted`

Client -> server:
- `typing` `{username,typing}`
- `read` `{username}`

## Admin
- `POST /api/admin/login`
- `GET /api/admin/me`
- `GET /api/admin/stats`
- `GET /api/admin/users?q=`
- `GET /api/admin/users/:username`
- `PATCH /api/admin/users/:username` supports `firstName,lastName,verified,banned,password`
- `DELETE /api/admin/users/:username`
- `GET /api/admin/messages?q=`
- `DELETE /api/admin/messages/:id`

Admin changes to `verified`, `banned`, profile name, and avatar state are pushed to connected clients. A banned user receives the `banned` event and is disconnected.
