# HROne Attendance Automation — Flutter App

## What it does
Automates your daily **punch-in** and **punch-out** on HROne HRMS at a time
you set. Runs in the background — no need to open the app.

---

## Setup (5 minutes)

### 1. Prerequisites
- Flutter SDK ≥ 3.0 ([install](https://docs.flutter.dev/get-started/install))
- Android device / emulator (API 21+) — iOS also supported

### 2. Install dependencies
```bash
cd hrone_attendance
flutter pub get
```

### 3. Run / build
```bash
# Debug run on connected device
flutter run

# Release APK
flutter build apk --release
# Output: build/outputs/flutter-apk/app-release.apk
```

---

## Using the app

### Account tab
- Enter your **Company Domain** (e.g. `mycompany` for `mycompany.hrone.cloud`)
- Enter your **HROne username/email** and **password**
- Tap **Save**, then **Test Connection** to verify

### Schedule tab
- Tap the **Punch-In** card → pick your entry time (e.g. 9:00 AM)
- Tap the **Punch-Out** card → pick your exit time (e.g. 6:00 PM)
- Toggle **Automation ON**
- Tap **Save & Apply Schedule**

### Status tab
- See last punch-in and punch-out status
- **Manual Override** buttons for immediate punching
- Tap ↻ to refresh status

---

## Android battery optimization (Important!)
On most Android phones, battery optimization kills background tasks.

1. Go to **Settings → Apps → HROne Attendance**
2. Tap **Battery**
3. Select **"Unrestricted"** (Samsung) or **"Don't optimize"**

---

## How the API works
```
POST https://api.hrone.cloud/api/v1/auth/login
  { "domain": "mycompany", "username": "...", "password": "..." }
  → { "data": { "token": "eyJ..." } }

POST https://api.hrone.cloud/api/v1/attendance/mark-attendance
  Authorization: Bearer <token>
  { "punchType": "IN", "punchTime": "2024-01-15T09:00:00" }
```

The app caches the token and auto-refreshes it on 401.

---

## Packages used
| Package | Purpose |
|---|---|
| `workmanager` | Background task scheduling (Android WorkManager) |
| `flutter_local_notifications` | Punch success/failure notifications |
| `shared_preferences` | Secure local storage for credentials & settings |
| `http` | REST API calls to HROne |
| `intl` | Date/time formatting |

---

## Privacy & Security
- Credentials stored **only on device** (SharedPreferences)
- No third-party servers; only `api.hrone.cloud` is contacted
- Token cached and auto-refreshed; password used only for login
