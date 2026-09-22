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
const sharp = require('sharp');

const PORT = Number(process.env.PORT || 2667);
const JWT_SECRET = process.env.JWT_SECRET || 'change-this-secret-in-pterodactyl';
const PUBLIC_BASE_URL = process.env.PUBLIC_BASE_URL || `http://malzoffc.pterocloud.my.id:${PORT}`;
const DATA_DIR = path.join(__dirname, 'data');
const UPLOAD_DIR = path.join(__dirname, 'uploads');
fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(path.join(UPLOAD_DIR, 'avatars'), { recursive: true });
fs.mkdirSync(path.join(UPLOAD_DIR, 'media'), { recursive: true });
fs.mkdirSync(path.join(UPLOAD_DIR, 'previews'), { recursive: true });
const DB_FILE = path.join(DATA_DIR, 'db.json');

const initial = { users: [], contacts: [], messages: [], hidden: [], admins: [] };
if (!fs.existsSync(DB_FILE)) fs.writeFileSync(DB_FILE, JSON.stringify(initial, null, 2));
let db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
for (const k of Object.keys(initial)) if (!Array.isArray(db[k])) db[k] = [];
// The built-in developer account is intentionally the only account allowed to create admin accounts.
// Credentials: admin / admin. Change DEV_PASSWORD immediately for any public deployment.
if (!db.admins.some(a => a.username === 'admin')) {
  db.admins.push({ username: 'admin', passwordHash: bcrypt.hashSync(process.env.DEV_PASSWORD || 'admin', 10), role: 'developer', createdAt: now() });
}
function save() { fs.writeFileSync(DB_FILE, JSON.stringify(db, null, 2)); }
function id() { return crypto.randomUUID(); }
function now() { return new Date().toISOString(); }
function safeUser(u) {
  return { username:u.username, firstName:u.firstName, lastName:u.lastName, name:`${u.firstName||''} ${u.lastName||''}`.trim(), displayName:`${u.firstName||''} ${u.lastName||''}`.trim(), verified:!!u.verified, badges:Array.isArray(u.badges)?u.badges:[], avatarUrl:u.avatarUrl||'' };
}
function tokenFor(u) { return jwt.sign({ username:u.username }, JWT_SECRET, { expiresIn:'30d' }); }
function getUser(username) { return db.users.find(u => u.username.toLowerCase() === String(username).toLowerCase()); }
function auth(req,res,next) {
  const raw = req.headers.authorization || '';
  if (!raw.startsWith('Bearer ')) return res.status(401).json({message:'Token diperlukan'});
  try { const p = jwt.verify(raw.slice(7), JWT_SECRET); const u=getUser(p.username); if(!u) return res.status(401).json({message:'Sesi tidak valid'}); if(u.banned) return res.status(403).json({message:'Akun diblokir'}); req.user=u; next(); }
  catch(e){ return res.status(401).json({message:'Token tidak valid'}); }
}
function hiddenAt(owner, other) { const h=db.hidden.find(x=>x.owner===owner&&x.other===other); return h?.before || null; }
function visibleMessages(owner, other) {
  const cutoff=hiddenAt(owner,other);
  return db.messages.filter(m => ((m.senderUsername===owner&&m.recipientUsername===other)||(m.senderUsername===other&&m.recipientUsername===owner)) && (!cutoff || m.createdAt>cutoff));
}
function messageOut(m) { return {...m, status:m.status||'sent'}; }
function emitUser(username, event, payload) { io.to(`user:${username}`).emit(event,payload); }
function contactFor(owner, username) {
  const c=db.contacts.find(c=>c.owner===owner&&c.username===username);
  const u=getUser(username);
  return { username, name:c?.name || u?.firstName && `${u.firstName||''} ${u.lastName||''}`.trim() || username, displayName:u?safeUser(u).displayName:username, avatarUrl:u?.avatarUrl||'', verified:!!u?.verified };
}

const app=express();
app.use(cors({origin:true,credentials:true}));
app.use(express.json({limit:'2mb'}));
app.use('/uploads/avatars',express.static(path.join(UPLOAD_DIR,'avatars')));
app.get('/',(req,res)=>res.json({name:'ChatWithU API',ok:true,version:'2.1.0',admin:'/admin'}));
app.get('/admin',(req,res)=>res.sendFile(path.join(__dirname,'admin.html')));
app.get('/health',(req,res)=>res.json({ok:true,time:now()}));
app.get('/media-preview/:id',(req,res)=>{const m=db.messages.find(x=>x.id===req.params.id);if(!m||m.type!=='image'||m.mediaAvailable===false||!m.previewFile)return res.status(404).end();const f=path.join(UPLOAD_DIR,'previews',path.basename(m.previewFile));if(!fs.existsSync(f))return res.status(404).end();res.sendFile(f);});

const avatarStorage=multer.diskStorage({destination:path.join(UPLOAD_DIR,'avatars'),filename:(req,file,cb)=>cb(null,`${Date.now()}-${crypto.randomBytes(5).toString('hex')}${path.extname(file.originalname).toLowerCase()}`)});
const mediaStorage=multer.diskStorage({destination:path.join(UPLOAD_DIR,'media'),filename:(req,file,cb)=>cb(null,`${Date.now()}-${crypto.randomBytes(5).toString('hex')}${path.extname(file.originalname).toLowerCase()}`)});
const avatarUpload=multer({storage:avatarStorage,limits:{fileSize:10*1024*1024},fileFilter:(req,file,cb)=>cb(null,String(file.mimetype||'').startsWith('image/'))});
const mediaUpload=multer({storage:mediaStorage,limits:{fileSize:50*1024*1024}});
const activeMediaDownloads=new Set();

app.post('/api/auth/register',async(req,res)=>{
  const {firstName='',lastName='',username='',password=''}=req.body||{}; const un=String(username).trim().toLowerCase();
  if(!un||String(password).length<4) return res.status(400).json({message:'Username dan password wajib diisi (password minimal 4 karakter).'});
  if(getUser(un)) return res.status(409).json({message:'Username sudah digunakan.'});
  const u={username:un,firstName:String(firstName).trim(),lastName:String(lastName).trim(),passwordHash:await bcrypt.hash(String(password),10),verified:false,badges:[],banned:false,avatarUrl:'',createdAt:now()};
  db.users.push(u); save(); res.json({token:tokenFor(u),user:safeUser(u)});
});
app.post('/api/auth/login',async(req,res)=>{
  const un=String(req.body?.username||'').trim().toLowerCase(); const u=getUser(un);
  if(!u||!(await bcrypt.compare(String(req.body?.password||''),u.passwordHash))) return res.status(401).json({message:'Username atau password salah.'});
  if(u.banned) return res.status(403).json({message:'Akun diblokir.'}); res.json({token:tokenFor(u),user:safeUser(u)});
});
app.get('/api/auth/me',auth,(req,res)=>res.json({user:safeUser(req.user)}));
app.patch('/api/auth/username',auth,async(req,res)=>{
  const next=String(req.body?.username||'').trim().toLowerCase(); if(!/^[a-z0-9_.-]{3,32}$/.test(next)) return res.status(400).json({message:'Username tidak valid.'});
  if(getUser(next)&&next!==req.user.username) return res.status(409).json({message:'Username sudah digunakan.'});
  const old=req.user.username; req.user.username=next;
  db.contacts.forEach(c=>{if(c.owner===old)c.owner=next;if(c.username===old)c.username=next;});
  db.messages.forEach(m=>{if(m.senderUsername===old)m.senderUsername=next;if(m.recipientUsername===old)m.recipientUsername=next;});
  db.hidden.forEach(h=>{if(h.owner===old)h.owner=next;if(h.other===old)h.other=next;}); save(); res.json({token:tokenFor(req.user),user:safeUser(req.user)});
});
app.post('/api/profile/avatar',auth,avatarUpload.single('file'),(req,res)=>{
  if(!req.file) return res.status(400).json({message:'File foto tidak valid.'});
  req.user.avatarUrl=`${PUBLIC_BASE_URL}/uploads/avatars/${req.file.filename}`; save(); emitUser(req.user.username,'profile:updated',{user:safeUser(req.user)}); res.json({user:safeUser(req.user)});
});
app.get('/api/users/:username',auth,(req,res)=>{const u=getUser(req.params.username);if(!u)return res.status(404).json({message:'User tidak ditemukan'});res.json(safeUser(u));});
function adminAuth(req,res,next){
  const raw=req.headers.authorization||'';
  if(!raw.startsWith('Bearer ')) return res.status(401).json({message:'Token admin diperlukan'});
  try{
    const p=jwt.verify(raw.slice(7),JWT_SECRET);
    const a=db.admins.find(x=>x.username===p.username);
    if(!a||!['developer','admin'].includes(a.role)||a.banned) throw new Error('role');
    req.admin={username:a.username,role:a.role};
    next();
  }catch(e){return res.status(401).json({message:'Token admin tidak valid'});}
}
app.post('/api/admin/login',async(req,res)=>{
  const user=String(req.body?.username||'').trim().toLowerCase();
  const pass=String(req.body?.password||'');
  const a=db.admins.find(x=>x.username===user);
  if(!a||a.banned||!(await bcrypt.compare(pass,a.passwordHash)))return res.status(401).json({message:'Login admin gagal'});
  res.json({token:jwt.sign({role:a.role,username:a.username},JWT_SECRET,{expiresIn:'7d'}),role:a.role,username:a.username});
});
app.get('/api/admin/me',adminAuth,(req,res)=>res.json({username:req.admin.username,role:req.admin.role}));
app.get('/api/admin/admins',adminAuth,(req,res)=>{
  res.json(db.admins.map(a=>({username:a.username,role:a.role,createdAt:a.createdAt,banned:!!a.banned})));
});
app.post('/api/admin/admins',adminAuth,async(req,res)=>{
  if(req.admin.role!=='developer') return res.status(403).json({message:'Hanya developer yang dapat membuat akun admin.'});
  const username=String(req.body?.username||'').trim().toLowerCase();
  const password=String(req.body?.password||'');
  if(!/^[a-z0-9_.-]{3,32}$/.test(username)) return res.status(400).json({message:'Username admin tidak valid.'});
  if(password.length<4) return res.status(400).json({message:'Password admin minimal 4 karakter.'});
  if(db.admins.some(a=>a.username===username)||getUser(username)) return res.status(409).json({message:'Username sudah digunakan.'});
  const a={username,passwordHash:await bcrypt.hash(password,10),role:'admin',banned:false,createdAt:now()};
  db.admins.push(a);save();res.json({username:a.username,role:a.role,createdAt:a.createdAt});
});
app.patch('/api/admin/admins/:username',adminAuth,async(req,res)=>{
  const a=db.admins.find(x=>x.username===String(req.params.username).toLowerCase());
  if(!a)return res.status(404).json({message:'Admin tidak ditemukan'});
  if(a.role==='developer'&&req.admin.username!==a.username)return res.status(403).json({message:'Akun developer tidak dapat diubah admin lain.'});
  if(req.body?.password!==undefined){if(String(req.body.password).length<4)return res.status(400).json({message:'Password minimal 4 karakter.'});a.passwordHash=await bcrypt.hash(String(req.body.password),10);}
  if(req.body?.banned!==undefined&&a.role!=='developer')a.banned=!!req.body.banned;
  save();res.json({username:a.username,role:a.role,banned:!!a.banned});
});
app.get('/api/admin/stats',adminAuth,(req,res)=>res.json({users:db.users.length,messages:db.messages.length,contacts:db.contacts.length}));
app.get('/api/admin/users',adminAuth,(req,res)=>{const q=String(req.query.q||'').toLowerCase();res.json(db.users.filter(u=>!q||JSON.stringify(safeUser(u)).toLowerCase().includes(q)).map(u=>({...safeUser(u),banned:!!u.banned})));});
app.get('/api/admin/users/:username',adminAuth,(req,res)=>{const u=getUser(req.params.username);if(!u)return res.status(404).json({message:'User tidak ditemukan'});res.json({...safeUser(u),banned:!!u.banned});});
app.patch('/api/admin/users/:username',adminAuth,async(req,res)=>{const u=getUser(req.params.username);if(!u)return res.status(404).json({message:'User tidak ditemukan'});for(const k of ['firstName','lastName'])if(req.body[k]!==undefined)u[k]=String(req.body[k]);if(req.body.verified!==undefined)u.verified=!!req.body.verified;if(req.body.banned!==undefined)u.banned=!!req.body.banned;if(req.body.badges!==undefined)u.badges=Array.isArray(req.body.badges)?req.body.badges.map(x=>String(x).trim()).filter(Boolean).slice(0,12):[];if(req.body.password!==undefined&&String(req.body.password).length>=4)u.passwordHash=await bcrypt.hash(String(req.body.password),10);save();emitUser(u.username,'profile:updated',{user:safeUser(u)});if(u.banned)emitUser(u.username,'banned',{});res.json({...safeUser(u),banned:!!u.banned});});
app.delete('/api/admin/users/:username',adminAuth,(req,res)=>{const u=String(req.params.username);db.users=db.users.filter(x=>x.username!==u);db.contacts=db.contacts.filter(x=>x.owner!==u&&x.username!==u);db.messages=db.messages.filter(x=>x.senderUsername!==u&&x.recipientUsername!==u);db.hidden=db.hidden.filter(x=>x.owner!==u&&x.other!==u);save();res.json({ok:true});});
app.get('/api/admin/messages',adminAuth,(req,res)=>{const q=String(req.query.q||'').toLowerCase();res.json(db.messages.filter(m=>!q||JSON.stringify(m).toLowerCase().includes(q)).map(messageOut));});
app.delete('/api/admin/messages/:id',adminAuth,(req,res)=>{const before=db.messages.length;db.messages=db.messages.filter(m=>m.id!==req.params.id);save();res.json({ok:db.messages.length!==before});});

app.get('/api/contacts',auth,(req,res)=>res.json(db.contacts.filter(c=>c.owner===req.user.username).map(c=>contactFor(req.user.username,c.username))));
app.get('/api/inbox',auth,(req,res)=>{
  const others=[...new Set(db.messages.filter(m=>m.senderUsername===req.user.username||m.recipientUsername===req.user.username).map(m=>m.senderUsername===req.user.username?m.recipientUsername:m.senderUsername))];
  const out=others.map(u=>{const msgs=visibleMessages(req.user.username,u);const last=msgs[msgs.length-1];const c=contactFor(req.user.username,u);return {...c,lastMessage:last?.type==='text'?last.message:last?`[${last.type}]`:'',lastMessageAt:last?.createdAt||null,unread:msgs.filter(m=>m.recipientUsername===req.user.username&&m.status!=='read').length};});
  return res.json(out);
});
app.post('/api/contacts',auth,(req,res)=>{const username=String(req.body?.username||'').trim().toLowerCase();const name=String(req.body?.name||'').trim();if(!getUser(username))return res.status(404).json({message:'User tidak ditemukan'});if(db.contacts.some(c=>c.owner===req.user.username&&c.username===username))return res.status(409).json({message:'Kontak sudah ada'});db.contacts.push({owner:req.user.username,username,name:name||contactFor(req.user.username,username).name});save();res.json({ok:true});});
app.patch('/api/contacts/:username',auth,(req,res)=>{const c=db.contacts.find(c=>c.owner===req.user.username&&c.username===req.params.username);if(!c)return res.status(404).json({message:'Kontak tidak ditemukan'});c.name=String(req.body?.name||'').trim()||c.name;save();res.json({ok:true,name:c.name});});
app.delete('/api/contacts/:username',auth,(req,res)=>{db.contacts=db.contacts.filter(c=>!(c.owner===req.user.username&&c.username===req.params.username));save();res.json({ok:true});});

app.get('/api/sync',auth,(req,res)=>{const contacts=db.contacts.filter(c=>c.owner===req.user.username).map(c=>contactFor(req.user.username,c.username));const inbox=[];const users=new Set(db.messages.filter(m=>m.senderUsername===req.user.username||m.recipientUsername===req.user.username).map(m=>m.senderUsername===req.user.username?m.recipientUsername:m.senderUsername));for(const u of users){const msgs=visibleMessages(req.user.username,u);const last=msgs[msgs.length-1];const c=contactFor(req.user.username,u);inbox.push({...c,lastMessage:last?.type==='text'?last.message:last?`[${last.type}]`:'',lastMessageAt:last?.createdAt||null,unread:msgs.filter(m=>m.recipientUsername===req.user.username&&m.status!=='read').length});}res.json({user:safeUser(req.user),contacts,inbox,serverTime:now()});});

app.get('/api/chats/:username/messages',auth,(req,res)=>{const other=String(req.params.username);let msgs=visibleMessages(req.user.username,other);const since=req.query.since?Date.parse(req.query.since):NaN;if(Number.isFinite(since))msgs=msgs.filter(m=>Date.parse(m.updatedAt||m.createdAt)>since);res.json(msgs.map(messageOut));});
app.post('/api/chats/:username/messages',auth,(req,res)=>{const other=String(req.params.username);if(!getUser(other))return res.status(404).json({message:'User tidak ditemukan'});const text=String(req.body?.message||'').trim();if(!text)return res.status(400).json({message:'Pesan kosong'});const m={id:id(),type:'text',message:text,url:'',mediaUrl:'',senderUsername:req.user.username,recipientUsername:other,status:'sent',createdAt:now(),updatedAt:now()};db.messages.push(m);save();emitUser(other,'message:new',messageOut(m));emitUser(req.user.username,'message:new',messageOut(m));res.json(m);});
app.post('/api/chats/:username/media',auth,mediaUpload.single('file'),async(req,res)=>{const other=String(req.params.username);if(!getUser(other))return res.status(404).json({message:'User tidak ditemukan'});if(!req.file)return res.status(400).json({message:'File tidak valid'});const type=['image','video','file'].includes(req.body?.type)?req.body.type:'file'; const mime=String(req.file.mimetype||'').toLowerCase(); if(type==='image'&&!mime.startsWith('image/')) return res.status(400).json({message:'Lampiran bukan foto.'}); if(type==='video'&&!mime.startsWith('video/')) return res.status(400).json({message:'Lampiran bukan video.'});const mId=id();const url=`${PUBLIC_BASE_URL}/uploads/media/${req.file.filename}`;const downloadUrl=`${PUBLIC_BASE_URL}/api/media/${mId}/download`;let previewFile='';if(type==='image'){previewFile=`${mId}.jpg`;try{await sharp(req.file.path).resize(600,600,{fit:'inside',withoutEnlargement:true}).jpeg({quality:45,mozjpeg:true}).toFile(path.join(UPLOAD_DIR,'previews',previewFile));}catch(e){previewFile='';}}const previewUrl=previewFile?`${PUBLIC_BASE_URL}/media-preview/${mId}`:'';const m={id:mId,type,message:req.file.originalname,url,mediaUrl:url,downloadUrl,previewUrl,storageFile:req.file.filename,previewFile,fileName:req.file.originalname,mimeType:req.file.mimetype,fileSize:req.file.size,mediaAvailable:true,senderUsername:req.user.username,recipientUsername:other,status:'sent',createdAt:now(),updatedAt:now()};db.messages.push(m);save();emitUser(other,'message:new',m);emitUser(req.user.username,'message:new',m);res.json(m);});
app.get('/api/media/:id/download',auth,(req,res)=>{const m=db.messages.find(x=>x.id===req.params.id);if(!m||!['image','video'].includes(m.type))return res.status(404).json({message:'Media tidak ditemukan'});if(m.recipientUsername!==req.user.username)return res.status(403).json({message:'Media hanya bisa diambil oleh penerima.'});if(m.mediaAvailable===false)return res.status(410).json({message:'Media sudah diambil dari server.'});if(activeMediaDownloads.has(m.id))return res.status(409).json({message:'Media sedang diunduh.'});const filename=path.basename(String(m.storageFile||''));if(!filename)return res.status(404).json({message:'File media tidak tersedia.'});const filePath=path.join(UPLOAD_DIR,'media',filename);if(!fs.existsSync(filePath)){m.mediaAvailable=false;save();return res.status(410).json({message:'File media sudah tidak tersedia.'});}activeMediaDownloads.add(m.id);res.download(filePath,m.fileName||filename,(err)=>{activeMediaDownloads.delete(m.id);if(err)return;fs.unlink(filePath,(unlinkErr)=>{if(unlinkErr&&unlinkErr.code!=='ENOENT')console.error('Gagal menghapus media:',unlinkErr);if(m.previewFile){const previewPath=path.join(UPLOAD_DIR,'previews',path.basename(m.previewFile));fs.unlink(previewPath,()=>{});}m.mediaAvailable=false;m.updatedAt=now();save();});});});
app.post('/api/chats/:username/read',auth,(req,res)=>{const other=String(req.params.username);db.messages.forEach(m=>{if(m.senderUsername===other&&m.recipientUsername===req.user.username)m.status='read';});save();emitUser(other,'message:read',{username:req.user.username,other});res.json({ok:true});});
app.post('/api/chats/:username/clear',auth,(req,res)=>{const other=String(req.params.username);db.hidden=db.hidden.filter(h=>!(h.owner===req.user.username&&h.other===other));db.hidden.push({owner:req.user.username,other,before:now()});save();res.json({ok:true});});
app.get('/api/chats/:username/search',auth,(req,res)=>{const q=String(req.query.q||'').trim().toLowerCase();if(!q)return res.json([]);res.json(visibleMessages(req.user.username,String(req.params.username)).filter(m=>String(m.message||m.fileName||'').toLowerCase().includes(q)).map(messageOut));});
app.get('/api/chats/:username/media',auth,(req,res)=>{const msgs=visibleMessages(req.user.username,String(req.params.username));res.json({media:msgs.filter(m=>m.type==='image'||m.type==='video'),docs:msgs.filter(m=>m.type==='file'),links:msgs.filter(m=>m.type==='text'&&/(https?:\/\/|www\.)/i.test(m.message||''))});});

const server=http.createServer(app); const io=new Server(server,{cors:{origin:'*'}});
const sockets=new Map();
io.use((socket,next)=>{try{const token=socket.handshake.auth?.token;const p=jwt.verify(token,JWT_SECRET);const u=getUser(p.username);if(!u||u.banned)return next(new Error('banned'));socket.user=u;next();}catch(e){next(new Error('unauthorized'));}});
io.on('connection',socket=>{const u=socket.user.username;socket.join(`user:${u}`);sockets.set(socket.id,u);socket.on('typing:start',({to}={})=>{if(to)emitUser(String(to),'typing',{from:u,typing:true});});socket.on('typing:stop',({to}={})=>{if(to)emitUser(String(to),'typing',{from:u,typing:false});});socket.on('message:read',({other}={})=>{if(other)emitUser(String(other),'message:read',{username:u,other});});socket.on('disconnect',()=>sockets.delete(socket.id));});

server.listen(PORT,'0.0.0.0',()=>console.log(`ChatWithU server listening on 0.0.0.0:${PORT}`));
