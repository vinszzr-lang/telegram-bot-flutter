// --- SCRIPT OTOMATIS CEK IP ---
const https = require('https');
function logPublicIP() {
    https.get('https://api.ipify.org', (resp) => {
        let data = '';
        resp.on('data', (chunk) => { data += chunk; });
        resp.on('end', () => {
            console.log(`=========================================`);
            console.log(` 🌐 IP PUBLIC SERVER INI ADALAH: ${data}`);
            console.log(` Gunakan IP ini untuk Whitelist di Atlantic!`);
            console.log(`=========================================`);
        });
    }).on("error", (err) => {
        console.log("Gagal deteksi IP otomatis: ", err.message);
    });
}
logPublicIP(); 
// ------------------------------

const express = require('express');
const cors = require('cors');
const axios = require('axios');
const path = require('path');
const admin = require('firebase-admin');
const config = require('./config');

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Inisialisasi Firebase Admin
admin.initializeApp({
    credential: admin.credential.cert(config.FIREBASE_CONFIG),
    databaseURL: config.FIREBASE_CONFIG.databaseURL
});
const db = admin.firestore();

app.use(express.static(path.join(__dirname, 'public')));

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'login.html'));
});

// [API Register, Login, Deposit, Dll tetap seperti yang terakhir kita bahas...]
// (Pastikan semua API Create Deposit sudah menggunakan .toString() pada nominal)

app.listen(config.PORT, () => {
    console.log(`=========================================`);
    console.log(` Server VinzzPay Berhasil Berjalan!`);
    console.log(` Port Internal : ${config.PORT}`);
    console.log(` URL Akses     : ${config.DOMAIN}`);
    console.log(`=========================================`);
});
