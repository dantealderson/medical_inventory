# Putting the test version online (free)

About 20 minutes of clicking, with no payment card. Afterwards you can test from anywhere, without your PC or a cable, and so can anyone you send the links to.

## What you get

- **Backend:** runs on **Render**, with its database on **Neon**. Both free.
- **Admin website:** `https://dantealderson.github.io/medical_inventory/`
- **Clinics' app:** one link to open on any Android phone:
  `https://github.com/dantealderson/medical_inventory/releases/download/test-build/medical-inventory.apk`
- **Demo data on the first start,** so there is something to try at once:
  - 13 items in 3 sections, with stock;
  - 2 approved clinics and 1 waiting for approval;
  - a delivery and two stock counts, so «عيادة النور» has red, yellow and green items;
  - an order waiting for you to confirm.
- **Updates on their own:** every change pushed to GitHub updates the server, the website and the app link.

## Good to know first

- **The free server sleeps** after 15 minutes without use. The next request takes up to a minute while it wakes. The app shows «تعذر الاتصال بالخادم»: wait a moment, then tap «إعادة المحاولة».
  - The nightly jobs (00:30) don't run on a night the server is asleep. «تشغيل الآن» on the dashboard runs them by hand.
  - Optional: a free service like cron-job.org can open `https://<your-server>/api/v1/health` every 10 minutes, which keeps the server awake.
- **The app link is public,** like the repository. Anyone who has it can install the test app. It only reaches the test server and its demo data.
- **The free database holds 0.5 GB.** That's plenty, even with pictures (about 150 KB each).

---

## Step 1: the database, on Neon (5 minutes)

1. Open **neon.tech** and sign up. A Google account works.
2. Create a project:
   - name: `medinv`;
   - Postgres version: 16;
   - region: **Frankfurt (EU Central)**, the closest to Iraq.
3. On the project page, press **Connect**:
   - switch **off** "Connection pooling";
   - copy the connection string. It starts with `postgresql://` and ends with `sslmode=require`.

## Step 2: the backend, on Render (10 minutes, mostly waiting)

1. Open **render.com** and sign up **with GitHub**.
2. Press **New → Blueprint**, and choose the repository `dantealderson/medical_inventory`. Render finds `render.yaml` and shows one service, `medinv-backend`.
3. Fill in the four values it asks for:

   | Name | What to put |
   |---|---|
   | `DATABASE_URL` | the Neon connection string from step 1 |
   | `SEED_ADMIN_USERNAME` | your admin username, for example `admin` |
   | `SEED_ADMIN_PASSWORD` | **a strong password.** This server is on the internet. |
   | `DEMO_CLINIC_PASSWORD` | the password for the demo clinics, at least 8 characters |

4. Press **Apply**. The first build takes about 10 minutes.
5. When the service says **Live**, open `https://<its address>/api/v1/health`. The address is shown at the top, for example `https://medinv-backend.onrender.com`. The page should show `"status":"ok","database":"up"`.
6. Keep that address for step 3.

## Step 3: the admin website and the app, on GitHub (5 minutes, then waiting)

1. On GitHub, open the repository, then **Settings → Pages**. Under "Build and deployment", set **Source: GitHub Actions**.
2. Open **Settings → Secrets and variables → Actions**, then the **Variables** tab, then **New repository variable**:
   - Name: `API_BASE_URL`
   - Value: your server's address from step 2, followed by `/api/v1`. For example: `https://medinv-backend.onrender.com/api/v1`
3. Open the **Actions** tab, choose **Build the apps**, and press **Run workflow**. It takes about 10 minutes.
4. **Admin:** open `https://dantealderson.github.io/medical_inventory/` and sign in with the admin username and password from step 2.
5. **Phone:**
   - Open the app link in the phone's browser:
     `https://github.com/dantealderson/medical_inventory/releases/download/test-build/medical-inventory.apk`
   - Download it and install it. When Android asks, allow installing from that browser.
   - **If the version installed over the USB cable is still on the phone, uninstall it first.** The two are signed differently, so Android refuses to replace one with the other ("App not installed").

## The demo accounts

All use the `DEMO_CLINIC_PASSWORD` from step 2.

| Username | Clinic | State |
|---|---|---|
| `clinic_alnoor` | عيادة النور | approved; has history: red syringes, yellow paracetamol, an order waiting |
| `clinic_alshifa` | مجمع الشفاء الطبي | approved; one delivery, one order confirmed |
| `lab_alamal` | مختبر الأمل | waiting for your approval |

## Later

- **Demo data only ever fills an empty catalogue,** so leaving `DEMO_DATA=true` is harmless. To stop it anyway, set it to `false` on Render (the service's Environment tab).
- **To start again from fresh demo data:**
  1. In Neon, open your project, then **Databases**.
  2. Delete `neondb` and create it again with the same name.
  3. On Render, choose **Manual Deploy → Restart service**. The admin and the demo data are created again.
- **The admin's password is set once,** on the first start. Changing `SEED_ADMIN_PASSWORD` on Render later does not change it, and the apps have no "change my password" screen yet. To change it, ask me.
