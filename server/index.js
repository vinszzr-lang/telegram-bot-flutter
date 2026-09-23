const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const cors = require('cors');
const multer = require('multer');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { Server } = require('socket.io');

const PORT = Number(process.env.PORT || 5042);
const JWT_SECRET = String(process.env.JWT_SECRET || 'CHANGE_ME_NOW');
const ADMIN_USERNAME = String(process.env.ADMIN_USERNAME || 'admin');
// Default admin credential requested for this build. Pterodactyl ADMIN_PASSWORD still overrides it when provided.
const ADMIN_PASSWORD = String(process.env.ADMIN_PASSWORD || 'admin');
const CONFIGURED_PUBLIC_BASE_URL = String(process.env.PUBLIC_BASE_URL || 'http://cloudadp.rexzystr.my.id:5042').replace(/\/$/, '');
const DATA_DIR = path.join(__dirname, 'data');
const UPLOAD_DIR = path.join(__dirname, 'uploads');
const DB_FILE = path.join(DATA_DIR, 'db.json');

if (JWT_SECRET.length < 32 || JWT_SECRET === 'CHANGE_ME_NOW') {
  console.warn('[SECURITY] Set a long random JWT_SECRET in Pterodactyl environment.');
}
if (ADMIN_PASSWORD === 'admin') {
  console.warn('[SECURITY] Default admin password is active. Change it after first login.');
}

for (const dir of [DATA_DIR, path.join(UPLOAD_DIR, 'avatars'), path.join(UPLOAD_DIR, 'media')]) {
  fs.mkdirSync(dir, { recursive: true });
}

const initial = {
  settings: {
    appName: 'X Chat',
    maintenance: false,
    registrationEnabled: true,
    maxUploadMb: 50,
    announcement: ''
  },
  users: [], contacts: [], messages: [], hidden: [], admins: [], activity: [], groups: [], groupMembers: []
};
if (!fs.existsSync(DB_FILE)) fs.writeFileSync(DB_FILE, JSON.stringify(initial, null, 2));
let db;
try { db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8')); } catch { db = structuredClone(initial); }
for (const [k, v] of Object.entries(initial)) {
  if (Array.isArray(v) && !Array.isArray(db[k])) db[k] = [];
  if (!Array.isArray(v) && (!db[k] || typeof db[k] !== 'object')) db[k] = v;
}
let saveTimer = null;
let saveInProgress = false;
function save() {
  const payload = JSON.stringify(db, null, 2);
  const tmp = `${DB_FILE}.tmp`;
  try {
    fs.writeFileSync(tmp, payload, 'utf8');
    fs.renameSync(tmp, DB_FILE);
  } catch (err) {
    try { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); } catch {}
    console.error('[DB] save failed:', err.message);
  }
}
function saveSoon(delay=250) {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => { save(); saveTimer = null; }, delay);
}
function backupDb() {
  try {
    const backup = `${DB_FILE}.bak`;
    fs.copyFileSync(DB_FILE, backup);
  } catch (err) {
    console.error('[DB] backup failed:', err.message);
  }
}
function id() { return crypto.randomUUID(); }
function now() { return new Date().toISOString(); }
function cleanText(v, max=120) { return String(v ?? '').trim().slice(0, max); }
function publicBaseUrl(req) {
  // Prefer an explicitly configured public URL. Otherwise derive the URL from
  // the request so production clients never receive http://127.0.0.1:5201.
  if (CONFIGURED_PUBLIC_BASE_URL && !/127\.0\.0\.1|localhost/i.test(CONFIGURED_PUBLIC_BASE_URL)) return CONFIGURED_PUBLIC_BASE_URL;
  const forwardedHost = String(req?.headers?.['x-forwarded-host'] || '').split(',')[0].trim();
  const host = forwardedHost || String(req?.headers?.host || '').trim();
  const forwardedProto = String(req?.headers?.['x-forwarded-proto'] || '').split(',')[0].trim();
  const proto = forwardedProto || (req?.secure ? 'https' : 'http');
  return host ? `${proto}://${host}` : (CONFIGURED_PUBLIC_BASE_URL || `http://127.0.0.1:${PORT}`);
}
function uploadUrl(req, kind, filename) {
  return `${publicBaseUrl(req)}/uploads/${kind}/${encodeURIComponent(filename)}`;
}
function rewriteUploadUrl(req, value) {
  const raw = String(value || '');
  if (!raw) return '';
  try {
    const u = new URL(raw, publicBaseUrl(req));
    if (u.pathname.startsWith('/uploads/')) return `${publicBaseUrl(req)}${u.pathname}${u.search}${u.hash}`;
  } catch {}
  return raw;
}
function getUser(username) { return db.users.find(u => u.username.toLowerCase() === String(username).toLowerCase()); }
function displayName(u) { return `${u.firstName || ''} ${u.lastName || ''}`.trim() || u.username; }
function safeUser(u, req) {
  return {
    username: u.username,
    firstName: u.firstName || '',
    lastName: u.lastName || '',
    name: displayName(u),
    displayName: displayName(u),
    bio: u.bio || '',
    verified: !!u.verified,
    banned: !!u.banned,
    badges: Array.isArray(u.badges) ? u.badges : [],
    avatarUrl: rewriteUploadUrl(req, u.avatarUrl || ''),
    createdAt: u.createdAt || null,
    updatedAt: u.updatedAt || null,
    lastSeenAt: u.lastSeenAt || null
  };
}
function tokenForUser(u) { return jwt.sign({ username: u.username, role: 'user' }, JWT_SECRET, { expiresIn: '30d' }); }
function addActivity(type, actor, target, meta={}) {
  db.activity.unshift({ id: id(), type, actor: actor || 'system', target: target || '', meta, createdAt: now() });
  db.activity = db.activity.slice(0, 500);
}
function auth(req, res, next) {
  const raw = req.headers.authorization || '';
  if (!raw.startsWith('Bearer ')) return res.status(401).json({ message: 'Token diperlukan' });
  try {
    const p = jwt.verify(raw.slice(7), JWT_SECRET);
    if (p.role !== 'user') throw new Error('role');
    const u = getUser(p.username);
    if (!u) return res.status(401).json({ message: 'Sesi tidak valid' });
    if (u.banned) return res.status(403).json({ message: 'Akun diblokir' });
    u.lastSeenAt = now(); u.updatedAt = now();
    req.user = u; next();
  } catch { return res.status(401).json({ message: 'Token tidak valid' }); }
}
function adminRecord(username = ADMIN_USERNAME) {
  return Array.isArray(db.admins) ? db.admins.find(a => a.username === String(username).toLowerCase()) : null;
}
function adminAuth(req, res, next) {
  const raw = req.headers.authorization || '';
  if (!raw.startsWith('Bearer ')) return res.status(401).json({ message: 'Token admin diperlukan' });
  try {
    const p = jwt.verify(raw.slice(7), JWT_SECRET);
    if (p.role !== 'admin' && p.role !== 'developer') throw new Error('role');
    const username = String(p.username || '').toLowerCase();
    const account = adminRecord(username);
    if (!account && username !== ADMIN_USERNAME.toLowerCase()) throw new Error('account');
    req.admin = { ...p, username, role: account?.role || (username === ADMIN_USERNAME.toLowerCase() ? 'developer' : 'admin') };
    next();
  } catch { return res.status(401).json({ message: 'Token admin tidak valid' }); }
}
function hiddenAt(owner, other) { return db.hidden.find(x => x.owner === owner && x.other === other)?.before || null; }
function visibleMessages(owner, other) {
  const cutoff = hiddenAt(owner, other);
  return db.messages.filter(m => ((m.senderUsername === owner && m.recipientUsername === other) || (m.senderUsername === other && m.recipientUsername === owner)) && (!cutoff || m.createdAt > cutoff));
}
function messageOut(m, req) { return { ...m, url: rewriteUploadUrl(req, m.url || ''), mediaUrl: rewriteUploadUrl(req, m.mediaUrl || ''), status: m.status || 'sent' }; }
function emitUser(username, event, payload) { io.to(`user:${String(username).toLowerCase()}`).emit(event, payload); }
function profileAudience(username) {
  const out = new Set();
  for (const c of db.contacts) if (c.username === username) out.add(c.owner);
  for (const m of db.messages) {
    if (m.senderUsername === username) out.add(m.recipientUsername);
    if (m.recipientUsername === username) out.add(m.senderUsername);
  }
  out.delete(username);
  return [...out];
}
function groupMessageOut(m, req, viewer) { const u=getUser(m.senderUsername); const saved=viewer?db.contacts.find(c=>c.owner===viewer&&c.username===m.senderUsername):null; return {...messageOut(m,req),senderName:saved?.name || (u?displayName(u):m.senderUsername),senderAvatarUrl:rewriteUploadUrl(req,u?.avatarUrl||''),senderVerified:!!u?.verified}; }
function emitGroupUpdate(groupId) { const g=getGroup(groupId); if(!g)return; for(const member of db.groupMembers.filter(m=>m.groupId===String(groupId))) emitUser(member.username,'group:updated',{group:safeGroup(g,member.username)}); }
function emitGroupMessage(groupId,m,req) { for(const member of db.groupMembers.filter(x=>x.groupId===String(groupId))) emitUser(member.username,'group:message:new',groupMessageOut(m,req,member.username)); }

function broadcastProfileUpdated(user, req) {
  const payload = { user: safeUser(user, req) };
  emitUser(user.username, 'profile:updated', payload);
  for (const recipient of profileAudience(user.username)) emitUser(recipient, 'profile:updated', payload);
}
function contactFor(owner, username, req) {
  const c = db.contacts.find(x => x.owner === owner && x.username === username);
  const u = getUser(username);
  return { username, name: c?.name || (u ? displayName(u) : username), displayName: u ? displayName(u) : username, avatarUrl: rewriteUploadUrl(req, u?.avatarUrl || ''), verified: !!u?.verified, badges: u?.badges || [], banned: !!u?.banned };
}

function getGroup(groupId) { return db.groups.find(g => g.id === String(groupId)); }
function groupMember(groupId, username) { return db.groupMembers.find(m => m.groupId === String(groupId) && m.username === String(username).toLowerCase()); }
function isGroupMember(groupId, username) { return !!groupMember(groupId, username); }
function groupRole(groupId, username) { return groupMember(groupId, username)?.role || null; }
function groupAdmin(groupId, username) { const r = groupRole(groupId, username); return r === 'owner' || r === 'admin'; }
function safeGroup(group, viewer) {
  const members = db.groupMembers.filter(m => m.groupId === group.id);
  const memberUsers = members.map(m => { const u = getUser(m.username); const saved = viewer ? db.contacts.find(c => c.owner === viewer && c.username === m.username) : null; return { username:m.username, name:saved?.name || (u ? displayName(u) : m.username), avatarUrl:u?.avatarUrl || '', verified:!!u?.verified, role:m.role }; });
  return { id:group.id, name:group.name, description:group.description || '', avatarUrl:rewriteUploadUrl(null, group.avatarUrl || ''), createdBy:group.createdBy, createdAt:group.createdAt, onlyAdminsManage:group.onlyAdminsManage !== false, memberCount:members.length, role:groupRole(group.id, viewer), members:memberUsers };
}
function visibleGroupMessages(groupId, username) {
  if (!isGroupMember(groupId, username)) return [];
  return db.messages.filter(m => m.groupId === String(groupId));
}
function groupSummary(group, username) {
  const msgs=visibleGroupMessages(group.id,username);
  const last=msgs[msgs.length-1];
  const unread=msgs.filter(m=>m.senderUsername!==username && m.readBy?.includes(username)!==true).length;
  return {...safeGroup(group,username),lastMessage:last?.type==='text'?last.message:last?`[${last.type}]`:'',lastMessageAt:last?.createdAt||null,unread};
}
function emitGroup(groupId, event, payload) { const members=db.groupMembers.filter(m=>m.groupId===String(groupId)); for (const m of members) emitUser(m.username,event,payload); }

function paginate(items, page=1, limit=50) {
  page = Math.max(1, Number(page) || 1); limit = Math.min(200, Math.max(1, Number(limit) || 50));
  const total = items.length, start = (page - 1) * limit;
  return { items: items.slice(start, start + limit), page, limit, total, pages: Math.max(1, Math.ceil(total / limit)) };
}
function userStats(username) {
  const sent = db.messages.filter(m => m.senderUsername === username).length;
  const received = db.messages.filter(m => m.recipientUsername === username).length;
  const contacts = db.contacts.filter(c => c.owner === username).length;
  const media = db.messages.filter(m => m.senderUsername === username && m.type !== 'text').length;
  return { sent, received, totalMessages: sent + received, contacts, media };
}

const app = express();
app.disable('x-powered-by');
app.use(cors({ origin: true, credentials: true }));
app.use(express.json({ limit: '2mb' }));
app.use('/uploads', express.static(UPLOAD_DIR, { maxAge: '1d' }));
app.get('/', (req,res) => res.json({ name: 'ChatWithU API', ok: true, version: '4.0.0', port: PORT, admin: '/admin' }));
app.get('/health', (req,res) => res.json({
  ok: true,
  time: now(),
  uptime: process.uptime(),
  users: db.users.length,
  online: onlineUsers?.size || 0,
  messages: db.messages.length,
  memory: process.memoryUsage().rss,
  node: process.version
}));
app.get('/admin', (req,res) => res.sendFile(path.join(__dirname, 'admin.html')));

const avatarStorage = multer.diskStorage({ destination: path.join(UPLOAD_DIR,'avatars'), filename: (req,file,cb) => cb(null, `${Date.now()}-${crypto.randomBytes(5).toString('hex')}${path.extname(file.originalname).toLowerCase()}`) });
const mediaStorage = multer.diskStorage({ destination: path.join(UPLOAD_DIR,'media'), filename: (req,file,cb) => cb(null, `${Date.now()}-${crypto.randomBytes(5).toString('hex')}${path.extname(file.originalname).toLowerCase()}`) });
const avatarUpload = multer({ storage: avatarStorage, limits: { fileSize: 10*1024*1024 }, fileFilter: (req,file,cb) => { const mime=String(file.mimetype||'').toLowerCase(); const ext=path.extname(file.originalname||'').toLowerCase(); const okMime=mime.startsWith('image/'); const okExt=['.jpg','.jpeg','.png','.webp','.gif','.heic','.heif','.avif'].includes(ext); cb(null, okMime || okExt); } });
const mediaUpload = multer({ storage: mediaStorage, limits: { fileSize: 50*1024*1024 } });

app.post('/api/auth/register', async (req,res) => {
  if (db.settings.maintenance) return res.status(503).json({ message: 'Server sedang maintenance.' });
  if (db.settings.registrationEnabled === false) return res.status(403).json({ message: 'Registrasi sedang ditutup.' });
  const firstName=cleanText(req.body?.firstName,60), lastName=cleanText(req.body?.lastName,60), un=cleanText(req.body?.username,32).toLowerCase(), password=String(req.body?.password||'');
  if (!/^[a-z0-9_.-]{3,32}$/.test(un)) return res.status(400).json({ message: 'Username 3-32 karakter: a-z, 0-9, _, ., -.' });
  if (password.length < 6) return res.status(400).json({ message: 'Password minimal 6 karakter.' });
  if (getUser(un)) return res.status(409).json({ message: 'Username sudah digunakan.' });
  const u={ username:un, firstName, lastName, bio:'', passwordHash:await bcrypt.hash(password,12), verified:false, badges:[], banned:false, avatarUrl:'', createdAt:now(), updatedAt:now(), lastSeenAt:now() };
  db.users.push(u); addActivity('user.register',un,un); save(); res.json({ token:tokenForUser(u), user:safeUser(u, req) });
});
app.post('/api/auth/login', async (req,res) => {
  const un=cleanText(req.body?.username,32).toLowerCase(), u=getUser(un);
  if(!u || !(await bcrypt.compare(String(req.body?.password||''),u.passwordHash))) return res.status(401).json({message:'Username atau password salah.'});
  if(u.banned) return res.status(403).json({message:'Akun diblokir.'});
  u.lastSeenAt=now();u.updatedAt=now();save();res.json({token:tokenForUser(u),user:safeUser(u, req)});
});
app.get('/api/auth/me',auth,(req,res)=>res.json({user:safeUser(req.user, req),settings:db.settings}));
app.patch('/api/auth/profile',auth,(req,res)=>{
  if(req.body.firstName!==undefined)req.user.firstName=cleanText(req.body.firstName,60);
  if(req.body.lastName!==undefined)req.user.lastName=cleanText(req.body.lastName,60);
  if(req.body.bio!==undefined)req.user.bio=cleanText(req.body.bio,160);
  req.user.updatedAt=now();save();broadcastProfileUpdated(req.user, req);res.json({user:safeUser(req.user, req)});
});
app.patch('/api/auth/username',auth,(req,res)=>{const next=cleanText(req.body?.username,32).toLowerCase();if(!/^[a-z0-9_.-]{3,32}$/.test(next))return res.status(400).json({message:'Username tidak valid.'});if(getUser(next)&&next!==req.user.username)return res.status(409).json({message:'Username sudah digunakan.'});const old=req.user.username;req.user.username=next;for(const c of db.contacts){if(c.owner===old)c.owner=next;if(c.username===old)c.username=next;}for(const m of db.messages){if(m.senderUsername===old)m.senderUsername=next;if(m.recipientUsername===old)m.recipientUsername=next;}for(const h of db.hidden){if(h.owner===old)h.owner=next;if(h.other===old)h.other=next;}addActivity('user.username_change',old,next);save();res.json({token:tokenForUser(req.user),user:safeUser(req.user, req)});});
app.post('/api/profile/avatar',auth,avatarUpload.single('file'),(req,res)=>{if(!req.file)return res.status(400).json({message:'File foto tidak valid.'});req.user.avatarUrl=uploadUrl(req,'avatars',req.file.filename);req.user.updatedAt=now();save();broadcastProfileUpdated(req.user, req);res.json({user:safeUser(req.user, req)});});
app.get('/api/users/:username',auth,(req,res)=>{const u=getUser(req.params.username);if(!u)return res.status(404).json({message:'User tidak ditemukan'});res.json(safeUser(u, req));});

// Mobile home sync endpoints: contacts must be returned together with inbox so a newly-added contact appears immediately.
app.get('/api/inbox',auth,(req,res)=>{ const users=[...new Set(db.messages.filter(m=>m.senderUsername===req.user.username||m.recipientUsername===req.user.username).map(m=>m.senderUsername===req.user.username?m.recipientUsername:m.senderUsername))]; const inbox=users.map(u=>{ const msgs=visibleMessages(req.user.username,u); const last=msgs[msgs.length-1]; return {...contactFor(req.user.username,u,req),lastMessage:last?.type==='text'?last.message:last?`[${last.type}]`:'',lastMessageAt:last?.createdAt||null,unread:msgs.filter(m=>m.recipientUsername===req.user.username&&m.status!=='read').length}; }); res.json(inbox); });
app.get('/api/sync',auth,(req,res)=>{ const users=[...new Set(db.messages.filter(m=>m.senderUsername===req.user.username||m.recipientUsername===req.user.username).map(m=>m.senderUsername===req.user.username?m.recipientUsername:m.senderUsername))]; const inbox=users.map(u=>{ const msgs=visibleMessages(req.user.username,u); const last=msgs[msgs.length-1]; return {...contactFor(req.user.username,u,req),lastMessage:last?.type==='text'?last.message:last?`[${last.type}]`:'',lastMessageAt:last?.createdAt||null,unread:msgs.filter(m=>m.recipientUsername===req.user.username&&m.status!=='read').length}; }); const groups=db.groups.filter(g=>isGroupMember(g.id,req.user.username)).map(g=>groupSummary(g,req.user.username)); res.json({user:safeUser(req.user, req),contacts:db.contacts.filter(c=>c.owner===req.user.username).map(c=>contactFor(req.user.username,c.username,req)),inbox,groups,serverTime:now(),settings:db.settings}); });

async function verifyAdminPassword(username, password) {
  const name = String(username).toLowerCase();
  const existing = adminRecord(name);
  if (existing?.passwordHash) return bcrypt.compare(String(password), existing.passwordHash);
  if (name !== ADMIN_USERNAME.toLowerCase()) return false;
  const a = Buffer.from(String(password));
  const b = Buffer.from(ADMIN_PASSWORD);
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}
app.post('/api/admin/login', async (req,res)=>{
  const username=String(req.body?.username||'').trim().toLowerCase();
  const password=String(req.body?.password||'');
  if(!(await verifyAdminPassword(username,password))) return res.status(401).json({message:'Login admin gagal'});
  const rec=adminRecord(username);
  const role=rec?.role || (username===ADMIN_USERNAME.toLowerCase()?'developer':'admin');
  addActivity('admin.login',username,role); save();
  res.json({token:jwt.sign({role,username},JWT_SECRET,{expiresIn:'7d'}),username,role});
});
app.post('/api/admin/password',adminAuth,async(req,res)=>{
  const current=String(req.body?.currentPassword||'');
  const next=String(req.body?.newPassword||'');
  const confirm=String(req.body?.confirmPassword||'');
  if(next.length<8)return res.status(400).json({message:'Password baru minimal 8 karakter.'});
  if(next!==confirm)return res.status(400).json({message:'Konfirmasi password tidak sama.'});
  if(!(await verifyAdminPassword(req.admin.username,current)))return res.status(401).json({message:'Password admin saat ini salah.'});
  const hash=await bcrypt.hash(next,12);
  const existing=adminRecord(req.admin.username);
  if(existing){existing.passwordHash=hash;existing.updatedAt=now();}
  else{db.admins.push({username:req.admin.username,passwordHash:hash,role:'developer',createdAt:now(),updatedAt:now()});}
  addActivity('admin.password_change',req.admin.username,req.admin.username);save();
  res.json({ok:true,message:'Password admin berhasil diubah.'});
});
app.get('/api/admin/me',adminAuth,(req,res)=>res.json({username:req.admin.username,role:req.admin.role}));
app.get('/api/admin/admins',adminAuth,(req,res)=>{
  if(req.admin.role!=='developer') return res.status(403).json({message:'Hanya developer yang dapat mengelola akun admin.'});
  const items=(db.admins||[]).map(a=>({username:a.username,role:a.role||'admin',createdAt:a.createdAt||null,updatedAt:a.updatedAt||null}));
  if(!items.some(a=>a.username===ADMIN_USERNAME.toLowerCase())) items.unshift({username:ADMIN_USERNAME.toLowerCase(),role:'developer',createdAt:null,updatedAt:null});
  res.json({items});
});
app.post('/api/admin/admins',adminAuth,async(req,res)=>{
  if(req.admin.role!=='developer') return res.status(403).json({message:'Hanya developer yang dapat membuat akun admin.'});
  const username=String(req.body?.username||'').trim().toLowerCase();
  const password=String(req.body?.password||'');
  if(!/^[a-z0-9_.-]{3,32}$/.test(username)) return res.status(400).json({message:'Username admin 3-32 karakter (a-z, 0-9, _, ., -).'});
  if(password.length<8) return res.status(400).json({message:'Password admin minimal 8 karakter.'});
  if(username===ADMIN_USERNAME.toLowerCase() || adminRecord(username)) return res.status(409).json({message:'Username admin sudah ada.'});
  db.admins.push({username,passwordHash:await bcrypt.hash(password,12),role:'admin',createdAt:now(),updatedAt:now()});
  addActivity('admin.create',req.admin.username,username);save();
  res.json({ok:true,username,role:'admin'});
});
app.delete('/api/admin/admins/:username',adminAuth,(req,res)=>{
  if(req.admin.role!=='developer') return res.status(403).json({message:'Hanya developer yang dapat menghapus akun admin.'});
  const username=String(req.params.username).toLowerCase();
  if(username===ADMIN_USERNAME.toLowerCase()) return res.status(400).json({message:'Akun developer utama tidak dapat dihapus.'});
  const before=db.admins.length; db.admins=db.admins.filter(a=>a.username!==username);
  if(before===db.admins.length) return res.status(404).json({message:'Admin tidak ditemukan.'});
  addActivity('admin.delete',req.admin.username,username);save();res.json({ok:true});
});

app.get('/api/admin/overview',adminAuth,(req,res)=>{
  const today=Date.now()-86400000;
  res.json({ users:db.users.length, verified:db.users.filter(u=>u.verified).length, banned:db.users.filter(u=>u.banned).length, online:onlineUsers.size, messages:db.messages.length, media:db.messages.filter(m=>m.type!=='text').length, contacts:db.contacts.length, registrations24h:db.users.filter(u=>Date.parse(u.createdAt||0)>=today).length, settings:db.settings, uptime:process.uptime(), memory:process.memoryUsage().rss });
});
function folderSize(dir) {
  let total=0;
  try {
    for(const ent of fs.readdirSync(dir,{withFileTypes:true})) {
      const p=path.join(dir,ent.name);
      if(ent.isDirectory()) total+=folderSize(p); else { try { total+=fs.statSync(p).size; } catch {} }
    }
  } catch {}
  return total;
}
app.get('/api/admin/stats',adminAuth,(req,res)=>res.json({
  users:db.users.length,
  messages:db.messages.length,
  contacts:db.contacts.length,
  groups:db.groups.length,
  verified:db.users.filter(u=>u.verified).length,
  banned:db.users.filter(u=>u.banned).length,
  online:onlineUsers.size
}));
app.get('/api/admin/health',adminAuth,(req,res)=>res.json({
  ok:true,
  time:now(),
  uptime:process.uptime(),
  memory:process.memoryUsage().rss,
  heapUsed:process.memoryUsage().heapUsed,
  heapTotal:process.memoryUsage().heapTotal,
  node:process.version,
  platform:process.platform,
  arch:process.arch,
  pid:process.pid,
  port:PORT,
  dbBytes:fs.existsSync(DB_FILE)?fs.statSync(DB_FILE).size:0,
  uploadBytes:folderSize(UPLOAD_DIR),
  online:onlineUsers.size,
  sockets:io.engine?.clientsCount || 0
}));
app.get('/api/admin/settings',adminAuth,(req,res)=>res.json(db.settings));
app.post('/api/admin/backup',adminAuth,(req,res)=>{
  try{
    save();
    backupDb();
    res.json({ok:true,download:null,message:'Backup dibuat di data/db.json.bak'});
  }catch(err){res.status(500).json({message:'Backup gagal: '+err.message});}
});
app.patch('/api/admin/settings',adminAuth,(req,res)=>{if(req.body.maintenance!==undefined)db.settings.maintenance=!!req.body.maintenance;if(req.body.registrationEnabled!==undefined)db.settings.registrationEnabled=!!req.body.registrationEnabled;if(req.body.announcement!==undefined)db.settings.announcement=cleanText(req.body.announcement,500);if(req.body.maxUploadMb!==undefined)db.settings.maxUploadMb=Math.min(200,Math.max(1,Number(req.body.maxUploadMb)||50));addActivity('admin.settings',req.admin.username,'settings',req.body);save();res.json(db.settings);});
function adminUserView(u){return {...safeUser(u),stats:userStats(u.username),passwordHash:undefined,online:onlineUsers.has(u.username)};}
app.get('/api/admin/users',adminAuth,(req,res)=>{let users=[...db.users];const q=String(req.query.q||'').trim().toLowerCase();const status=String(req.query.status||'all');const badge=String(req.query.badge||'').trim().toLowerCase();if(q)users=users.filter(u=>JSON.stringify(safeUser(u)).toLowerCase().includes(q));if(status==='banned')users=users.filter(u=>u.banned);if(status==='verified')users=users.filter(u=>u.verified);if(status==='online')users=users.filter(u=>onlineUsers.has(u.username));if(status==='offline')users=users.filter(u=>!onlineUsers.has(u.username));if(badge)users=users.filter(u=>(u.badges||[]).some(b=>String(b).toLowerCase()===badge));users.sort((a,b)=>String(b.createdAt).localeCompare(String(a.createdAt)));res.json(paginate(users.map(adminUserView),req.query.page,req.query.limit));});
app.get('/api/admin/users/:username',adminAuth,(req,res)=>{const u=getUser(req.params.username);if(!u)return res.status(404).json({message:'User tidak ditemukan'});res.json(adminUserView(u));});
app.patch('/api/admin/users/:username',adminAuth,async(req,res)=>{const u=getUser(req.params.username);if(!u)return res.status(404).json({message:'User tidak ditemukan'});if(req.body.firstName!==undefined)u.firstName=cleanText(req.body.firstName,60);if(req.body.lastName!==undefined)u.lastName=cleanText(req.body.lastName,60);if(req.body.bio!==undefined)u.bio=cleanText(req.body.bio,160);if(req.body.verified!==undefined)u.verified=!!req.body.verified;if(req.body.banned!==undefined)u.banned=!!req.body.banned;if(req.body.badges!==undefined)u.badges=Array.isArray(req.body.badges)?[...new Set(req.body.badges.map(x=>cleanText(x,32)).filter(Boolean))].slice(0,20):[];if(req.body.password!==undefined){const p=String(req.body.password);if(p.length<6)return res.status(400).json({message:'Password minimal 6 karakter.'});u.passwordHash=await bcrypt.hash(p,12);}u.updatedAt=now();addActivity('admin.user_update',req.admin.username,u.username,{verified:u.verified,banned:u.banned,badges:u.badges});save();emitUser(u.username,'profile:updated',{user:safeUser(u, req)});if(u.banned)emitUser(u.username,'banned',{});res.json(adminUserView(u));});
app.post('/api/admin/users/:username/password',adminAuth,async(req,res)=>{const u=getUser(req.params.username);if(!u)return res.status(404).json({message:'User tidak ditemukan'});const p=String(req.body?.password||'');if(p.length<6)return res.status(400).json({message:'Password minimal 6 karakter.'});u.passwordHash=await bcrypt.hash(p,12);u.updatedAt=now();addActivity('admin.password_reset',req.admin.username,u.username);save();res.json({ok:true});});
app.delete('/api/admin/users/:username',adminAuth,(req,res)=>{const u=String(req.params.username).toLowerCase();if(!getUser(u))return res.status(404).json({message:'User tidak ditemukan'});db.users=db.users.filter(x=>x.username!==u);db.contacts=db.contacts.filter(x=>x.owner!==u&&x.username!==u);db.messages=db.messages.filter(x=>x.senderUsername!==u&&x.recipientUsername!==u);db.hidden=db.hidden.filter(x=>x.owner!==u&&x.other!==u); db.groupMembers=db.groupMembers.filter(x=>x.username!==u); for(const g of db.groups){if(g.createdBy===u){const replacement=db.groupMembers.find(m=>m.groupId===g.id&&m.role==='admin')||db.groupMembers.find(m=>m.groupId===g.id); if(replacement){replacement.role='owner';g.createdBy=replacement.username;}else{db.groups=db.groups.filter(x=>x.id!==g.id);}}} addActivity('admin.user_delete',req.admin.username,u);save();res.json({ok:true});});
app.get('/api/admin/messages',adminAuth,(req,res)=>{let msgs=[...db.messages].sort((a,b)=>String(b.createdAt).localeCompare(String(a.createdAt)));const q=String(req.query.q||'').trim().toLowerCase();if(q)msgs=msgs.filter(m=>JSON.stringify(m).toLowerCase().includes(q));res.json(paginate(msgs.map(m => messageOut(m, req)),req.query.page,req.query.limit));});
app.delete('/api/admin/messages/:id',adminAuth,(req,res)=>{const before=db.messages.length;db.messages=db.messages.filter(m=>m.id!==req.params.id);addActivity('admin.message_delete',req.admin.username,req.params.id);save();res.json({ok:db.messages.length!==before});});
app.get('/api/admin/activity',adminAuth,(req,res)=>res.json(paginate(db.activity,req.query.page,req.query.limit)));

app.get('/api/contacts',auth,(req,res)=>res.json(db.contacts.filter(c=>c.owner===req.user.username).map(c=>contactFor(req.user.username,c.username,req))));
app.post('/api/contacts',auth,(req,res)=>{const username=cleanText(req.body?.username,32).toLowerCase();const u=getUser(username);if(!u)return res.status(404).json({message:'User tidak ditemukan'});if(username===req.user.username)return res.status(400).json({message:'Tidak bisa menambah diri sendiri'});if(!db.contacts.some(c=>c.owner===req.user.username&&c.username===username))db.contacts.push({owner:req.user.username,username,name:cleanText(req.body?.name,80)||displayName(u),createdAt:now()});save(); const out=contactFor(req.user.username,username,req); emitUser(req.user.username,'contacts:updated',{contact:out}); res.json(out);});
app.patch('/api/contacts/:username',auth,(req,res)=>{const username=decodeURIComponent(String(req.params.username||'')).toLowerCase();const contact=db.contacts.find(c=>c.owner===req.user.username&&c.username===username);if(!contact)return res.status(404).json({message:'Kontak tidak ditemukan.'});const name=cleanText(req.body?.name,80);if(!name)return res.status(400).json({message:'Nama kontak tidak boleh kosong.'});contact.name=name;save();const out=contactFor(req.user.username,username,req);emitUser(req.user.username,'contacts:updated',{contact:out});res.json(out);});
app.delete('/api/contacts/:username',auth,(req,res)=>{db.contacts=db.contacts.filter(c=>!(c.owner===req.user.username&&c.username===req.params.username));save();res.json({ok:true});});
app.get('/api/home',auth,(req,res)=>{const users=[...new Set(db.messages.filter(m=>m.senderUsername===req.user.username||m.recipientUsername===req.user.username).map(m=>m.senderUsername===req.user.username?m.recipientUsername:m.senderUsername))];const inbox=users.map(u=>{const msgs=visibleMessages(req.user.username,u);const last=msgs[msgs.length-1];return {...contactFor(req.user.username,u,req),lastMessage:last?.type==='text'?last.message:last?`[${last.type}]`:'',lastMessageAt:last?.createdAt||null,unread:msgs.filter(m=>m.recipientUsername===req.user.username&&m.status!=='read').length};});const groups=db.groups.filter(g=>isGroupMember(g.id,req.user.username)).map(g=>groupSummary(g,req.user.username)); res.json({user:safeUser(req.user, req),contacts:db.contacts.filter(c=>c.owner===req.user.username).map(c=>contactFor(req.user.username,c.username,req)),inbox,groups,serverTime:now(),settings:db.settings});});
app.get('/api/chats/:username/messages',auth,(req,res)=>{let msgs=visibleMessages(req.user.username,String(req.params.username));const since=req.query.since?Date.parse(req.query.since):NaN;if(Number.isFinite(since))msgs=msgs.filter(m=>Date.parse(m.updatedAt||m.createdAt)>since);res.json(msgs.map(m => messageOut(m, req)));});
app.post('/api/chats/:username/messages',auth,(req,res)=>{const other=String(req.params.username).toLowerCase();if(!getUser(other))return res.status(404).json({message:'User tidak ditemukan'});const text=cleanText(req.body?.message,4000);if(!text)return res.status(400).json({message:'Pesan kosong'});const m={id:id(),type:'text',message:text,url:'',mediaUrl:'',senderUsername:req.user.username,recipientUsername:other,status:'delivered',createdAt:now(),updatedAt:now()};db.messages.push(m);save();const out=messageOut(m,req);emitUser(other,'message:new',out);emitUser(req.user.username,'message:new',out);res.json(out);});
app.post('/api/chats/:username/media',auth,mediaUpload.single('file'),(req,res)=>{const other=String(req.params.username).toLowerCase();if(!getUser(other))return res.status(404).json({message:'User tidak ditemukan'});if(!req.file)return res.status(400).json({message:'File tidak valid'});const type=['image','video','sticker','file'].includes(req.body?.type)?req.body.type:'file';const caption=cleanText(req.body?.caption ?? req.body?.message ?? '',4000);const mime=String(req.file.mimetype||'').toLowerCase();const ext=path.extname(req.file.originalname||'').toLowerCase();const imageExts=['.jpg','.jpeg','.png','.webp','.gif','.heic','.heif','.avif'];const videoExts=['.mp4','.m4v','.mov','.webm','.mkv','.3gp','.avi'];const isImage=mime.startsWith('image/')||imageExts.includes(ext);const isVideo=mime.startsWith('video/')||videoExts.includes(ext);if((type==='image'||type==='sticker')&&!isImage)return res.status(400).json({message:'Lampiran bukan foto.'});if(type==='video'&&!isVideo)return res.status(400).json({message:'Lampiran bukan video.'});const url=uploadUrl(req,'media',req.file.filename);const m={id:id(),type,message:caption,url,mediaUrl:url,fileName:req.file.originalname,caption,mimeType:req.file.mimetype,size:req.file.size,senderUsername:req.user.username,recipientUsername:other,status:'delivered',mediaAvailable:true,storageFile:req.file.filename,createdAt:now(),updatedAt:now()};db.messages.push(m);save();emitUser(other,'message:new',messageOut(m, req));emitUser(req.user.username,'message:new',messageOut(m, req));res.json(messageOut(m, req));});


app.get('/api/groups',auth,(req,res)=>{
  const rows=db.groups.filter(g=>isGroupMember(g.id,req.user.username)).map(g=>groupSummary(g,req.user.username));
  rows.sort((a,b)=>String(b.lastMessageAt||b.createdAt).localeCompare(String(a.lastMessageAt||a.createdAt)));
  res.json(rows);
});
app.get('/api/groups/:id',auth,(req,res)=>{
  const g=getGroup(req.params.id); if(!g||!isGroupMember(g.id,req.user.username)) return res.status(404).json({message:'Grup tidak ditemukan.'});
  res.json(safeGroup(g,req.user.username));
});
app.post('/api/groups',auth, (req,res)=>{
  const name=cleanText(req.body?.name,80); const description=cleanText(req.body?.description,500);
  const usernames=Array.isArray(req.body?.members)?[...new Set(req.body.members.map(x=>String(x).trim().toLowerCase()).filter(Boolean))]:[];
  if(!name)return res.status(400).json({message:'Nama grup wajib diisi.'});
  if(usernames.length<1)return res.status(400).json({message:'Pilih minimal 1 kontak.'});
  const valid=[]; for(const u of usernames){if(u!==req.user.username&&getUser(u))valid.push(u);} if(valid.length!==usernames.length)return res.status(400).json({message:'Ada anggota yang tidak valid.'});
  const g={id:id(),name,description,createdBy:req.user.username,createdAt:now(),avatarUrl:'',onlyAdminsManage:true};
  db.groups.push(g); db.groupMembers.push({groupId:g.id,username:req.user.username,role:'owner',addedAt:now()});
  for(const u of valid)db.groupMembers.push({groupId:g.id,username:u,role:'member',addedAt:now()});
  save(); emitGroupUpdate(g.id); res.json(safeGroup(g,req.user.username));
});
app.post('/api/groups/:id/avatar',auth,avatarUpload.single('file'),(req,res)=>{const g=getGroup(req.params.id);if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});if(groupRole(g.id,req.user.username)!=='owner'&&groupRole(g.id,req.user.username)!=='admin')return res.status(403).json({message:'Hanya admin yang dapat mengganti foto grup.'});if(!req.file)return res.status(400).json({message:'Foto grup tidak valid.'});g.avatarUrl=uploadUrl(req,'avatars',req.file.filename);save();emitGroupUpdate(g.id);res.json(safeGroup(g,req.user.username));});
app.get('/api/groups/:id/messages',auth,(req,res)=>{
  const g=getGroup(req.params.id); if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});
  let msgs=visibleGroupMessages(g.id,req.user.username); const since=req.query.since?Date.parse(req.query.since):NaN; if(Number.isFinite(since))msgs=msgs.filter(m=>Date.parse(m.updatedAt||m.createdAt)>since); res.json(msgs.map(m=>groupMessageOut(m,req,req.user.username)));
});
app.post('/api/groups/:id/messages',auth,(req,res)=>{
  const g=getGroup(req.params.id); if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});
  const text=cleanText(req.body?.message,4000); if(!text)return res.status(400).json({message:'Pesan kosong'});
  const m={id:id(),groupId:g.id,type:'text',message:text,url:'',mediaUrl:'',senderUsername:req.user.username,status:'delivered',createdAt:now(),updatedAt:now(),readBy:[req.user.username]}; db.messages.push(m); save(); emitGroupMessage(g.id,m,req); res.json(groupMessageOut(m,req));
});
app.post('/api/groups/:id/media',auth,mediaUpload.single('file'),(req,res)=>{
  const g=getGroup(req.params.id); if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'}); if(!req.file)return res.status(400).json({message:'File tidak valid'});
  const type=['image','video','sticker','file'].includes(req.body?.type)?req.body.type:'file'; const caption=cleanText(req.body?.caption ?? req.body?.message ?? '',4000); const mime=String(req.file.mimetype||'').toLowerCase(); const ext=path.extname(req.file.originalname||'').toLowerCase(); const imageExts=['.jpg','.jpeg','.png','.webp','.gif','.heic','.heif','.avif']; const videoExts=['.mp4','.m4v','.mov','.webm','.mkv','.3gp','.avi']; const isImage=mime.startsWith('image/')||imageExts.includes(ext); const isVideo=mime.startsWith('video/')||videoExts.includes(ext); if((type==='image'||type==='sticker')&&!isImage)return res.status(400).json({message:'Lampiran bukan foto.'}); if(type==='video'&&!isVideo)return res.status(400).json({message:'Lampiran bukan video.'});
  const url=uploadUrl(req,'media',req.file.filename); const m={id:id(),groupId:g.id,type,message:caption,url,mediaUrl:url,fileName:req.file.originalname,caption,mimeType:req.file.mimetype,size:req.file.size,senderUsername:req.user.username,status:'delivered',mediaAvailable:true,storageFile:req.file.filename,createdAt:now(),updatedAt:now(),readBy:[req.user.username]}; db.messages.push(m); save(); emitGroupMessage(g.id,m,req); res.json(groupMessageOut(m,req));
});
app.post('/api/groups/:id/read',auth,(req,res)=>{const g=getGroup(req.params.id);if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});for(const m of db.messages.filter(m=>m.groupId===g.id)){if(!Array.isArray(m.readBy))m.readBy=[];if(!m.readBy.includes(req.user.username))m.readBy.push(req.user.username);m.updatedAt=now();}save();res.json({ok:true});});
app.post('/api/groups/:id/typing',auth,(req,res)=>{const g=getGroup(req.params.id);if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});emitGroup(g.id,'group:typing',{groupId:g.id,from:req.user.username,typing:req.body?.typing===true});res.json({ok:true});});
app.post('/api/groups/:id/members',auth,(req,res)=>{const g=getGroup(req.params.id);if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});if(g.onlyAdminsManage!==false&&!groupAdmin(g.id,req.user.username))return res.status(403).json({message:'Hanya admin yang dapat menambah anggota.'});const usernames=Array.isArray(req.body?.members)?req.body.members:[req.body?.username];const added=[];for(const raw of usernames){const u=String(raw||'').trim().toLowerCase();if(!u||u===req.user.username||!getUser(u)||isGroupMember(g.id,u))continue;db.groupMembers.push({groupId:g.id,username:u,role:'member',addedAt:now()});added.push(u);}if(!added.length)return res.status(400).json({message:'Tidak ada anggota baru.'});save();emitGroupUpdate(g.id);res.json(safeGroup(g,req.user.username));});
app.delete('/api/groups/:id/members/:username',auth,(req,res)=>{const g=getGroup(req.params.id);const target=String(req.params.username).toLowerCase();if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});if(g.onlyAdminsManage!==false&&!groupAdmin(g.id,req.user.username))return res.status(403).json({message:'Hanya admin yang dapat mengeluarkan anggota.'});const tm=groupMember(g.id,target);if(!tm)return res.status(404).json({message:'Anggota tidak ditemukan.'});if(tm.role==='owner')return res.status(403).json({message:'Pemilik grup tidak dapat dikeluarkan.'});db.groupMembers=db.groupMembers.filter(m=>!(m.groupId===g.id&&m.username===target));save();emitGroupUpdate(g.id);res.json({ok:true});});
app.patch('/api/groups/:id/members/:username/role',auth,(req,res)=>{const g=getGroup(req.params.id);const target=String(req.params.username).toLowerCase();const role=String(req.body?.role||'member');if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});if(groupRole(g.id,req.user.username)!=='owner')return res.status(403).json({message:'Hanya pembuat grup yang dapat mengatur admin.'});const tm=groupMember(g.id,target);if(!tm)return res.status(404).json({message:'Anggota tidak ditemukan.'});if(tm.role==='owner')return res.status(400).json({message:'Pemilik grup tidak dapat diturunkan.'});if(!['admin','member'].includes(role))return res.status(400).json({message:'Role tidak valid.'});tm.role=role;save();emitGroupUpdate(g.id);res.json({ok:true});});
app.patch('/api/groups/:id/settings',auth,(req,res)=>{const g=getGroup(req.params.id);if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});if(groupRole(g.id,req.user.username)!=='owner')return res.status(403).json({message:'Hanya pembuat grup yang dapat mengubah pengaturan ini.'});if(req.body.onlyAdminsManage!==undefined)g.onlyAdminsManage=!!req.body.onlyAdminsManage;if(req.body.name!==undefined)g.name=cleanText(req.body.name,80)||g.name;if(req.body.description!==undefined)g.description=cleanText(req.body.description,500);save();emitGroupUpdate(g.id);res.json(safeGroup(g,req.user.username));});
app.post('/api/groups/:id/leave',auth,(req,res)=>{const g=getGroup(req.params.id);if(!g||!isGroupMember(g.id,req.user.username))return res.status(404).json({message:'Grup tidak ditemukan.'});if(groupRole(g.id,req.user.username)==='owner')return res.status(403).json({message:'Pembuat grup tidak dapat keluar. Alihkan kepemilikan terlebih dahulu.'});db.groupMembers=db.groupMembers.filter(m=>!(m.groupId===g.id&&m.username===req.user.username));save();emitGroupUpdate(g.id);res.json({ok:true});});
app.get('/api/media/:id/download',auth,(req,res)=>{
  const m=db.messages.find(x=>x.id===req.params.id);
  if(!m||!['image','video','sticker'].includes(m.type)) return res.status(404).json({message:'Media tidak ditemukan'});
  if(m.groupId){ if(!isGroupMember(m.groupId,req.user.username)) return res.status(403).json({message:'Bukan anggota grup.'}); } else if(m.recipientUsername!==req.user.username) return res.status(403).json({message:'Media hanya bisa diambil oleh penerima.'});
  if(m.mediaAvailable===false) return res.status(410).json({message:'Media sudah diambil dari server.'});
  if(activeMediaDownloads.has(m.id)) return res.status(409).json({message:'Media sedang diunduh.'});
  const filename=path.basename(String(m.storageFile||path.basename(new URL(m.url||'').pathname||'')));
  if(!filename) return res.status(404).json({message:'File media tidak tersedia.'});
  const filePath=path.join(UPLOAD_DIR,'media',filename);
  if(!fs.existsSync(filePath)){m.mediaAvailable=false;save();return res.status(410).json({message:'File media sudah tidak tersedia.'});}
  activeMediaDownloads.add(m.id);
  res.download(filePath,m.fileName||filename,(err)=>{
    activeMediaDownloads.delete(m.id);
    if(err) return;
    if(!m.groupId){ fs.unlink(filePath,unlinkErr=>{if(unlinkErr&&unlinkErr.code!=='ENOENT')console.error('[MEDIA] delete failed',unlinkErr);}); m.mediaAvailable=false; }
    m.updatedAt=now();
    save();
  });
});
app.post('/api/chats/:username/read',auth,(req,res)=>{const other=String(req.params.username);db.messages.forEach(m=>{if(m.senderUsername===other&&m.recipientUsername===req.user.username)m.status='read';});save();emitUser(other,'message:read',{username:req.user.username,other});res.json({ok:true});});
app.post('/api/chats/:username/clear',auth,(req,res)=>{const other=String(req.params.username);db.hidden=db.hidden.filter(h=>!(h.owner===req.user.username&&h.other===other));db.hidden.push({owner:req.user.username,other,before:now()});save();res.json({ok:true});});
app.get('/api/chats/:username/search',auth,(req,res)=>{const q=String(req.query.q||'').trim().toLowerCase();if(!q)return res.json([]);res.json(visibleMessages(req.user.username,String(req.params.username)).filter(m=>String(m.message||m.fileName||'').toLowerCase().includes(q)).map(messageOut));});
app.get('/api/chats/:username/media',auth,(req,res)=>{const msgs=visibleMessages(req.user.username,String(req.params.username));res.json({media:msgs.filter(m=>m.type==='image'||m.type==='video'||m.type==='sticker').map(m=>messageOut(m,req)),docs:msgs.filter(m=>m.type==='file').map(m=>messageOut(m,req)),links:msgs.filter(m=>m.type==='text'&&/(https?:\/\/|www\.)/i.test(m.message||''))});});

const server=http.createServer(app);
const io=new Server(server,{cors:{origin:'*'}});
const onlineUsers=new Map();
const activeMediaDownloads = new Set();
io.use((socket,next)=>{try{const token=socket.handshake.auth?.token;const p=jwt.verify(token,JWT_SECRET);if(p.role!=='user')throw new Error('role');const u=getUser(p.username);if(!u||u.banned)return next(new Error('banned'));socket.user=u;next();}catch{next(new Error('unauthorized'));}});
io.on('connection',socket=>{const u=socket.user.username;socket.join(`user:${u}`);onlineUsers.set(u,(onlineUsers.get(u)||0)+1);emitUser(u,'presence', {online:true});socket.on('typing:start',({to}={})=>{const target=String(to||'').toLowerCase();if(target&&target!==u.toLowerCase())emitUser(target,'typing',{from:u,typing:true});});socket.on('typing:stop',({to}={})=>{const target=String(to||'').toLowerCase();if(target&&target!==u.toLowerCase())emitUser(target,'typing',{from:u,typing:false});});socket.on('message:read',({other}={})=>{if(other)emitUser(String(other),'message:read',{username:u,other});}); for(const gm of db.groupMembers.filter(m=>m.username===u)) socket.join(`group:${gm.groupId}`); socket.on('group:typing',({groupId,typing}={})=>{const g=getGroup(groupId);if(g&&isGroupMember(g.id,u))emitGroup(g.id,'group:typing',{groupId:g.id,from:u,typing:typing===true});}); socket.on('disconnect',()=>{const n=(onlineUsers.get(u)||1)-1;if(n<=0){onlineUsers.delete(u);const usr=getUser(u);if(usr){usr.lastSeenAt=now();usr.updatedAt=now();save();}emitUser(u,'presence',{online:false,lastSeenAt:usr?.lastSeenAt||now()});}else onlineUsers.set(u,n);});});

const shutdown = signal => {
  console.log(`[ChatWithU] ${signal} received, shutting down...`);
  try { save(); } catch {}
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 8000).unref();
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('uncaughtException', err => console.error('[FATAL] uncaughtException:', err));
process.on('unhandledRejection', err => console.error('[FATAL] unhandledRejection:', err));

server.listen(PORT,'0.0.0.0',()=>console.log(`[ChatWithU] listening on 0.0.0.0:${PORT}`));
