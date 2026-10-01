# Testing from anywhere, free, from this PC

No card and no monthly cost. Your PC is the server, and **ngrok** gives it a fixed public address, so the app on your phone reaches it from anywhere, on Wi-Fi or mobile data.

- **One address for everything:** `https://YOUR-DOMAIN/` is the admin website, and the phone app talks to `https://YOUR-DOMAIN/api/v1`.
- **The PC must be on**, with `start-online.cmd` running. Close its window and you are offline.
- **Free limits:** 20,000 requests and 1 GB a month, plenty for testing.
- **Its own database** (`medinv_online`), filled with the demo data on the first start. Your development database is never touched.
- The real hosting (`docs/HOSTING.md`, needs a card) can wait.

## Once: ngrok (5 minutes)

1. Sign up at **ngrok.com** with Google.
2. In the dashboard, open **Domains** and copy your free domain, e.g. `xxxx.ngrok-free.dev`.
3. Open **Your Authtoken** and copy the command it shows. Run it in a Command Prompt, with the full path to ngrok in place of the word `ngrok`:
   ```
   "%LOCALAPPDATA%\ngrok\ngrok.exe" config add-authtoken PASTE_YOUR_TOKEN_HERE
   ```
   The token is secret: never send it to anyone.

## Once: push notifications (optional, 2 minutes)

Download the Firebase key: https://console.firebase.google.com/project/iq-medsupply-app/settings/serviceaccounts/adminsdk then **Generate new private key**. Leave it in **Downloads**: `start-online.cmd` finds it there by itself.

## Once: the app for your phone (5 minutes, then about 10 minutes of waiting)

1. On GitHub, open the repository, then **Settings → Secrets and variables → Actions → Variables → New repository variable**:
   - Name: `API_BASE_URL`
   - Value: `https://YOUR-DOMAIN/api/v1`
2. **Settings → Pages**: set **Source: GitHub Actions** (the workflow publishes there too).
3. **Actions → Build the apps → Run workflow**.
4. On the phone, open and install:
   `https://github.com/dantealderson/medical_inventory/releases/download/test-build/medical-inventory.apk`
   Uninstall the old app called "client" first, if it is still there.

## Every time you want to test

1. Double-click **`start-online.cmd`** in `D:\PROJECTS\medical_inventory`.
   - The first time it asks for your ngrok domain. The demo clinics' password is in `online.local.json`.
   - It starts Docker, the database and the server, then shows **ONLINE** with your addresses.
2. Keep that window open. Test from the phone, from anywhere.
3. **Admin:** open `https://YOUR-DOMAIN/` in any browser, on the PC or the phone. The first visit shows an ngrok page: press **Visit Site**. Sign in with the admin username and password from `backend\.env`.

Demo accounts (password in `online.local.json`): `clinic_alnoor` (red, yellow and green items, an order waiting), `clinic_alshifa`, and `lab_alamal` (waiting for approval).

## If something is off

- **"Something is already using port 3000":** a development server is running. Stop it, then start again.
- **The server did not start:** its messages are in `online-server.log` and `online-server.log.err`, in the repository folder.
- **To start the demo data again:** delete the `medinv_online` database (`docker exec medinv_postgres dropdb -U medinv medinv_online`) and double-click `start-online.cmd`.
- **Only on this PC, no tunnel:** `start-online.cmd -NoTunnel`, then http://localhost:3000.
