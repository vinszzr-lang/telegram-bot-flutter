# ChatWithU API Contract

Base URL: `http://malzoffc.pterocloud.my.id:2667`

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

## Fast sync / near-real-time polling
- `GET /api/sync` -> `{user,contacts,inbox,serverTime}`.
- The Android home screen polls this endpoint every 1 second while visible.
- The chat screen polls the incremental messages endpoint every 1 second.
- The client does not use Socket.IO.

## Chats
- `GET /api/chats/:username/messages?since=<ISO timestamp>`
- `POST /api/chats/:username/messages` body `{type:"text",message}`
- `POST /api/chats/:username/media` multipart `file` + `type=image|video|file`; max 50 MiB

Message shape:
`{id,type,message,url,mediaUrl,senderUsername,recipientUsername,status,createdAt,updatedAt}`

Statuses: `sending`, `sent`, `delivered`, `read`, `failed`.

## Realtime transport
- Socket.IO is not required by the Android client.
- Near-real-time updates are provided by HTTP polling.

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
