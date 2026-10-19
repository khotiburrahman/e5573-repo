<div align="center">

# 📡 E5573 Control Script

### Kontrol Penuh Modem Huawei E5573 dari Terminal OpenWrt

[![Platform](https://img.shields.io/badge/platform-OpenWrt-blue?style=for-the-badge&logo=openwrt)](https://openwrt.org)
[![Shell](https://img.shields.io/badge/shell-POSIX-green?style=for-the-badge&logo=gnu-bash)](https://www.gnu.org/software/bash/)
[![Modem](https://img.shields.io/badge/modem-Huawei%20E5573-red?style=for-the-badge&logo=huawei)](https://www.huawei.com)
[![License](https://img.shields.io/badge/license-MIT-yellow?style=for-the-badge)](LICENSE)

**Ganti IP publik • Baca & kirim SMS • Lock band LTE • Monitor trafik — semua dari terminal!**

[Daftar Fitur](#-fitur-utama) • [Instalasi](#-instalasi) • [Konfigurasi](#-konfigurasi) • [Penggunaan](#-penggunaan) • [Troubleshooting](#-troubleshooting)

</div>

---

## 📖 Tentang

`login.sh` adalah script shell **POSIX** untuk mengontrol modem **Huawei E5573** (dan mungkin kompatibel dengan modem HiLink lain) melalui API web-nya. Dirancang untuk berjalan di perangkat **OpenWrt** seperti STB B860H, router mini, atau perangkat embedded lain.

Script ini **tidak memerlukan browser** — semua operasi dilakukan via HTTP API langsung, memanfaatkan endpoint tersembunyi modem yang biasanya hanya dipakai WebUI.

> ⚡ **Cocok untuk:** pengguna yang sering ganti IP publik, butuh otomasi SMS/OTP, monitoring jaringan, atau riset API modem Huawei.

---

## ✨ Fitur Utama

<table>
<tr>
<td width="50%">

### 🌐 Kontrol Jaringan
- 🔄 **Ganti IP publik** via band switch (B1 → B3 → B40)
- 📶 **Smart transit** — otomatis pilih band cadangan jika bentrok
- 🛡️ **Auto fallback** ke Data Off/On jika band switch gagal
- 🔒 **Lock band LTE** (single atau multi-band)
- 📊 **Monitor sinyal** lengkap (RSRP, RSRQ, SINR, PCI, Cell ID)
- 📡 **NetworkMode** fleksibel (LTE only / GSM / Auto)

</td>
<td width="50%">

### 📨 SMS Lengkap
- 📥 **Baca inbox/outbox/draft** dengan paginasi (10/page)
- ✉️ **Kirim SMS baru** dengan retry otomatis 3×
- 💬 **Balas SMS** tanpa menghapus pesan asli di Inbox
- 📝 **Kelola Konsep/Draft** — kirim ulang pesan gagal
- 🗑️ **Hapus pesan** individual atau seluruh folder
- 🔍 **Filter unread** untuk fokus pesan baru
- 🤖 **Auto-switch mode** — GSM 900 untuk SMS, LTE untuk internet

</td>
</tr>
<tr>
<td colspan="2">

### 🔧 Utilitas
- 🎛️ **Menu interaktif** dengan tampilan header (IP, sinyal, mode)
- 🖥️ **CLI mode** untuk scripting & cron
- 📈 **Monitoring trafik** (upload/download rate, total usage)
- 🔋 **Info baterai** & status SIM
- 💾 **Cache WAN IP** (30 detik) agar menu responsif
- 📚 **Help lengkap** — `./login.sh help`

</td>
</tr>
</table>

---

## 🚀 Instalasi

### Prasyarat

| Komponen | Versi | Keterangan |
|---|---|---|
| **OpenWrt** | 19.07+ | Minimal, sudah include di B860H/most router |
| **curl** | 7.66+ | Sudah terinstal default |
| **openssl** | 1.1+ | Untuk hashing password (SHA256) |
| **fold** | GNU coreutils | Untuk word-wrap SMS (opsional) |

Jika belum ada, install via:
```bash
opkg update
opkg install curl openssl-util coreutils-fold