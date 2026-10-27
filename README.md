# HROne Attendance Automation

> Flutter app that automatically marks your HROne HRMS punch-in and punch-out at a schedule you set — no need to open the app.

[![Build & Release APK](https://github.com/kamaleshdas1997/hrone-attendance-automation/actions/workflows/build.yml/badge.svg)](https://github.com/kamaleshdas1997/hrone-attendance-automation/actions/workflows/build.yml)

---

## Download APK

The latest APK is built automatically by GitHub Actions and attached to the [**Latest Release**](https://github.com/kamaleshdas1997/hrone-attendance-automation/releases/tag/latest).

> **Direct link:** https://github.com/kamaleshdas1997/hrone-attendance-automation/releases/download/latest/app-release.apk

Scan to download on your Android phone:

![QR Code](https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=https://github.com/kamaleshdas1997/hrone-attendance-automation/releases/download/latest/app-release.apk)

---

## Features

- **Automated punch-in & punch-out** at times you set
- **Background scheduling** via Android WorkManager (survives reboots)
- **Push notifications** on every punch success or failure
- **Domain auto-detection** from corporate email address
- **Manual override** buttons for immediate punch
- **Token caching** — logs in once, refreshes automatically on 401
- Credentials stored **only on device** — no third-party servers

---

## Setup

### Configure the app

**Account tab**
- Enter your **Company Domain** (e.g. `mycompany` → `mycompany.hrone.cloud`)
- Or type your corporate email and tap ✨ **Detect domain from email**
- Enter your **username / email** and **password**
- Tap **Save** then **Test Connection**

**Schedule tab**
- Set your **Punch-In time** (e.g. 9:00 AM)
- Set your **Punch-Out time** (e.g. 6:00 PM)
- Toggle **Automation ON**
- Tap **Save & Apply Schedule**

**Status tab**
- See last punch timestamps and status
- Use **Punch In Now / Punch Out Now** for immediate manual punches

### ⚠️ Battery optimization (important!)
1. **Settings → Apps → HROne Attendance**
2. Tap **Battery**
3. Select **Unrestricted** (Samsung) or **Don't optimize** (stock Android)

---

## Building from source

```bash
git clone https://github.com/kamaleshdas1997/hrone-attendance-automation
cd hrone-attendance-automation
flutter pub get
flutter build apk --release
# APK: build/app/outputs/flutter-apk/app-release.apk
```

---

## Packages

| Package | Purpose |
|---|---|
| `workmanager ^0.5.2` | Android WorkManager background tasks |
| `flutter_local_notifications ^17.0.0` | Punch notifications |
| `shared_preferences ^2.2.2` | Secure local storage |
| `http ^1.2.0` | REST API calls to HROne |
| `intl ^0.19.0` | Date/time formatting |

---

## Privacy & Security

- Credentials stored **only on device** (Android SharedPreferences)
- Only `api.hrone.cloud` is contacted
- No analytics, no telemetry, no third-party SDKs
