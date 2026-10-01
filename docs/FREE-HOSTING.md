# Testing from anywhere, free, from this PC

No card and no monthly cost. Your PC is the server, and a **Microsoft dev tunnel** gives it a fixed public address, so the app on your phone reaches it from anywhere, on Wi-Fi or mobile data. You sign in with your **GitHub** account; nothing else to sign up for. (ngrok is blocked in Iraq without a VPN, so it is not used.)

- **One address for everything:** `https://YOUR-TUNNEL-3000.euw.devtunnels.ms/` is the admin website, and the phone app talks to the same address plus `/api/v1`.
- **The PC must be on**, with `start-online.cmd` running. Close its window and you are offline.
- **Free limits:** 5 GB a month, plenty for testing. A tunnel unused for 30 days is deleted; the next start creates it again at the same address.
- **Its own database** (`medinv_online`), filled with the demo data on the first start. Your development database is never touched.
- The real hosting (`docs/HOSTING.md`, needs a card) can wait.

## Once: your address (2 minutes)

1. Double-click **`start-online.cmd`** in `D:\PROJECTS\medical_inventory`.
2. The first time, a browser window opens: sign in with **GitHub** and allow "Dev Tunnels".
3. It creates your tunnel and shows **ONLINE** with your addresses. Copy the line `app (API_BASE_URL): https://…/api/v1` and send it to me.

## Once: push notifications (optional, 2 minutes)

Download the Firebase key: https://console.firebase.google.com/project/iq-medsupply-app/settings/serviceaccounts/adminsdk then **Generate new private key**. Leave it in **Downloads**: `start-online.cmd` finds it there by itself, at the next start.

## Once: the app for your phone (5 minutes, then about 10 minutes of waiting)

1. On GitHub, open the repository, then **Settings → Secrets and variables → Actions → Variables → New repository variable**:
   - Name: `API_BASE_URL`
   - Value: the `app (API_BASE_URL)` address from the first start, ending in `/api/v1`
2. **Settings → Pages**: set **Source: GitHub Actions** (the workflow publishes there too).
3. **Actions → Build the apps → Run workflow**.
4. On the phone, open and install:
   `https://github.com/dantealderson/medical_inventory/releases/download/test-build/medical-inventory.apk`
   Uninstall the old app called "client" first, if it is still there.

## Every time you want to test

1. Double-click **`start-online.cmd`**. It starts Docker, the database, the server and the tunnel, then shows **ONLINE**.
2. Keep that window open. Test from the phone, from anywhere.
3. **Admin:** open the admin address it shows, in any browser, on the PC or the phone. The first visit shows a Microsoft page ("You are about to connect to a developer tunnel"): press **Continue**. Sign in with the admin username and password from `backend\.env`.

Demo accounts (their password is in `online.local.json`): `clinic_alnoor` (red, yellow and green items, an order waiting), `clinic_alshifa`, and `lab_alamal` (waiting for approval).

## If something is off

- **"Something is already using port 3000":** a development server is running. Stop it, then start again.
- **The server did not start:** its messages are in `online-server.log` and `online-server.log.err`, in the repository folder.
- **To start the demo data again:** delete the `medinv_online` database (`docker exec medinv_postgres dropdb -U medinv medinv_online`) and double-click `start-online.cmd`.
- **Only on this PC, no tunnel:** `start-online.cmd -NoTunnel`, then http://localhost:3000.
- **The tunnel tool** is `%LOCALAPPDATA%\devtunnel\devtunnel.exe`. Your tunnel's name is `tunnelId` in `online.local.json`.
