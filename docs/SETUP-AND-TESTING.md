# Medical Inventory: setup, testing and progress

*As of 30 September 2026. Phases 0–6 are done, plus "stop tracking an item".*

This file has three parts:
1. **What you need to do yourself** before you can try the system.
2. **Step-by-step tests** you can run by hand, with what you should see.
3. **Where the project stands**, and what is left.

Screens and buttons are named with their Arabic labels exactly as they appear in the apps, so you can find them.

---

## 1. What you need to do yourself

### 1.1 Install once

| Tool | Why | Check it works |
|---|---|---|
| **Docker Desktop** | Runs the database (PostgreSQL 16) | `docker ps` shows no error |
| **Node.js 22 or newer** | Runs the backend | `node -v` |
| **Flutter 3.32 or newer** (with Android Studio for the Android SDK and an emulator) | Builds the two apps | `flutter doctor` shows no red ✗ for Android and Chrome |
| **Google Chrome** | The admin app runs in the browser | — |

On this PC all four are already installed.

Docker Desktop is installed per-user. If a terminal says `docker: command not found`, open a new terminal, or run the line below (Git Bash):

```bash
export PATH="$PATH:/c/Users/ACER PC/AppData/Local/Programs/DockerDesktop/resources/bin"
```

### 1.2 Configure the backend (only once per machine)

On this PC, `backend/.env` already exists, so skip to 1.3. On a new machine:

1. Copy `backend/.env.example` to `backend/.env`.
2. Generate two **different** secrets and paste them into `JWT_ACCESS_SECRET` and `JWT_REFRESH_SECRET`:
   ```bash
   node -e "console.log(require('crypto').randomBytes(48).toString('base64url'))"
   ```
3. Set `SEED_ADMIN_PASSWORD` to the password you want for the admin account (at least 8 characters). The username is `SEED_ADMIN_USERNAME` (default `admin`).
4. Leave `JOBS_ENABLED=true`, so the nightly jobs run at 00:30 Baghdad time while the backend is running.
5. Leave `FIREBASE_SERVICE_ACCOUNT_JSON` empty for now (see 1.6).

### 1.3 Start the database and the backend

```bash
cd D:\PROJECTS\medical_inventory
docker compose up -d                 # the database, on port 5433

cd backend
npm install                          # first time, or after pulling new code
npx prisma migrate deploy            # creates or updates the tables
npx prisma generate
npm run db:seed                      # the admin account and the default settings (safe to re-run)
npm run start:dev                    # the API on http://localhost:3000
```

Checks:
- http://localhost:3000/api/v1/health answers.
- http://localhost:3000/api/docs opens the API documentation (Swagger). You won't need it for testing: the admin dashboard runs the nightly jobs for you.

Postgres is on port **5433** on purpose. A separate Windows PostgreSQL service uses 5432, and this project must never touch it.

### 1.4 Run the admin app (web)

```bash
cd D:\PROJECTS\medical_inventory\admin
flutter pub get
flutter run -d chrome
```

Sign in with the admin username and password from `backend/.env` (`SEED_ADMIN_USERNAME` / `SEED_ADMIN_PASSWORD`). You land on «الرئيسية», the dashboard.

### 1.5 Run the client app (the clinics' app)

**On the Android emulator** (easiest). Start an emulator from Android Studio, then:

```bash
cd D:\PROJECTS\medical_inventory\client
flutter pub get
flutter run
```

The emulator reaches your PC's backend at `10.0.2.2` automatically.

**On a real Android phone, with a USB cable** (recommended). This works on any network: the phone can stay on mobile data, because the app talks to your PC through the cable.
1. On the phone, turn on USB debugging: Settings → About phone → tap «Build number» 7 times. Then open Developer options and turn on «USB debugging». On Xiaomi/Redmi phones, also turn on «Install via USB».
2. Connect the phone to the PC with the cable. On the phone, accept «Allow USB debugging?».
3. Check that Flutter sees the phone: `flutter devices` should list it.
4. Forward the phone's port 3000 to your PC. In Command Prompt (cmd):
   ```bat
   "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" reverse tcp:3000 tcp:3000
   ```
   Or in PowerShell:
   ```powershell
   & "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" reverse tcp:3000 tcp:3000
   ```
5. Run the app on the phone:
   ```bash
   cd D:\PROJECTS\medical_inventory\client
   flutter run --dart-define=API_BASE_URL=http://127.0.0.1:3000/api/v1
   ```
6. The forwarding stops when you unplug the cable. After you plug it back in, run step 4 again. The app stays installed on the phone, so after that you can open it from the home screen. The backend must be running on the PC.

**On a real Android phone, over Wi-Fi** (only if the phone and the PC are on the same Wi-Fi):
1. Find your PC's local address: run `ipconfig`, and take the IPv4 address, e.g. `192.168.1.20`.
2. Allow port 3000 through Windows Firewall. The first time Node asks, choose "Allow"; otherwise add an inbound rule for TCP 3000.
3. Run:
   ```bash
   flutter run --dart-define=API_BASE_URL=http://192.168.1.20:3000/api/v1
   ```

**In Chrome** (quick look only; the real app is for phones): `flutter run -d chrome`.

### 1.6 Optional: push notifications to phones (Firebase)

Without this, every notification still appears inside both apps (the bell and the notifications screen). It just does not pop up on a locked phone. To turn it on:

1. **Choose the app's real id first** (see 1.7). Firebase is tied to it.
2. Create a project at https://console.firebase.google.com, then add an **Android app** with that id.
3. **Server side:**
   - In the Firebase console, go to *Project settings → Service accounts → Generate new private key*. This downloads a JSON file.
   - Put its whole content **on one line** in `backend/.env` as `FIREBASE_SERVICE_ACCOUNT_JSON=...`, then restart the backend. The log stops saying "push is off".
4. **App side:** tell me when steps 1–3 are done. I will wire `firebase_messaging` into the client app. That takes one `flutterfire configure` run on your machine, which needs your Google login.

### 1.7 Decisions only you can make

| Decision | Why it matters | Needed by |
|---|---|---|
| **The app's id**: currently the placeholder `com.example.client`, e.g. `iq.yourcompany.medinventory` | Google Play rejects `com.example…`; Firebase is tied to the id | Before Firebase, and before publishing |
| **The app's display name and icon** | What clinics see on their phones | Before publishing |
| **Hosting**: a cloud server (VPS) with Docker and a domain name, plus HTTPS | Phones need to reach the backend over the internet | Phase 7 (deployment) |
| **Google Play developer account** (one-time $25) | To publish the Android app | Publishing |
| **iPhone app**: needs a Mac and an Apple developer account ($99/year) | Only if clinics use iPhones | Optional |
| **The "day-30 «نفد»" behaviour** (see 3.4) | Whether a once-bought item shows «نفد» on day 30 | Any time |

### Troubleshooting

| Symptom | Fix |
|---|---|
| «تعذر الاتصال بالخادم» in an app | The backend is not running (1.3), or a phone cannot reach your PC (1.5: address and firewall) |
| `Can't reach database server at localhost:5433` | `docker compose up -d`, and wait ~5 seconds |
| Admin login fails | Re-run `npm run db:seed` after setting `SEED_ADMIN_PASSWORD` |
| The admin app loads but every list errors in Chrome | Make sure you opened it via `flutter run -d chrome` (the backend allows any `localhost` origin in development) |

---

## 2. Test it yourself, step by step

Do these in order. Each step says what you should see. Keep the admin app (Chrome) and the client app (emulator or phone) open side by side.

### A. Accounts

1. **Client app:** tap «إنشاء حساب». Enter a username, a password (8+ characters), a clinic name, a phone and an address, then send.
   → The app shows that the account is waiting for approval.
2. **Admin app:** on «الرئيسية», «حسابات بانتظار الموافقة» shows **1**. Tap it (or the «طلبات الحسابات» tab). The new clinic is listed as pending. Open it and tap «موافقة».
3. **Client app:** sign in.
   → The home screen: search bar, «مخزوني», categories. The bell shows **1**: «تمت الموافقة على حسابك».

### B. Build a small catalogue (admin)

4. **Categories tab:** create a category, e.g. «مستهلكات».
5. **Items tab:** create two items, for example:
   - «سرنجة 5 مل»: 100 per box, unit «سرنجة», price 12.50, minimum 1 box;
   - «شاش»: 10 per box, unit «لفة», price 4.00.
6. **Batches tab:** receive stock for each item:
   - one batch of «سرنجة» expiring in about **8 months**, 20 boxes;
   - one batch of «سرنجة» expiring in about **40 days**, 5 boxes;
   - one batch of «شاش», 20 boxes.

   The 40-day batch is there to test expiry warnings and the "earliest expiry first" rule.

### C. Order (client) and confirm (admin)

7. **Client app:** open the category. Tap the big **+** on «سرنجة 5 مل» three times.
   → A message confirms each box. The cart icon shows 1 line.
8. Open the cart. Try **+** and **−** quickly, then tap «إرسال الطلب».
   → You land on the order, status «بانتظار التأكيد».
9. **Admin app:** the bell/notifications tab shows «طلب جديد من …». In the **orders tab**, open the order and tap «معاينة التخصيص».
   → The preview uses the batch expiring soonest that still has more than 30 days of shelf life (the 40-day one first).
10. Tap «تأكيد الطلب», then «إرسال للتوصيل», then «تأكيد التسليم».
11. **Client app:** the bell shows «تم تأكيد طلبك», «طلبك في الطريق إليك» and «تم توصيل طلبك». Tapping one opens the order.
12. **Short-order check:** place an order for more boxes than are in stock, and confirm it.
    → The admin sees «تم تأكيد الطلب مع نقص في بعض الأصناف», and the clinic is told the same.

### D. My Inventory and the stock count (client)

13. Tap «مخزوني».
    → «سرنجة 5 مل» shows the delivered quantity in boxes and units, a badge that is a colour **and** a word, and «لا توجد بيانات كافية». There is no usage estimate yet, which is correct for a first purchase.
14. Tap the item.
    → Its history lists «استلام طلب» with the batch number.
15. Back on «مخزوني», tap «جرد المخزون». Type a slightly smaller number of boxes than you have, and tap «حفظ الجرد» → «متابعة».
    → The result says «نقص …». The item's history now shows «تصحيح بالجرد».

### E. Low-stock warnings and the + on red (admin + client)

16. **Admin app:** open the clinic's account and tap «مخزون العميل». Tap the item, set «الحد الأدنى (علب)» above what the clinic has, and save.
17. **Client app:** go back to home.
    → «أصناف تحتاج إلى طلب» lists the item with a big **+**. In «مخزوني», its badge is red, «ناقص».
18. Tap that **+**.
    → One box is added to the cart.

### F. The nightly jobs, without waiting for midnight

The jobs run by themselves at 00:30 Baghdad time. To run them now:

19. **Admin app, «الرئيسية»:** in the «التحديث الليلي» card, tap «تشغيل الآن».
    → It shows «تم بنجاح» and the time. This includes the check that every quantity still matches its history.
20. **Client app:** the bell shows «…: الكمية قليلة» for the red item. The 40-day batch you hold shows «دفعة … تنتهي في …».
21. Run the jobs again.
    → No duplicate notifications. A red item is re-announced only once a week.

**Seeing automatic subtraction in one sitting** (it normally counts days):
- **Admin app:** in «مخزون العميل», set «معدل الاستهلاك (وحدة/يوم)» to e.g. `20`.
- In a terminal:
  ```bash
  cd backend
  npx prisma studio
  ```
  Open `client_inventory_items`, find the row, and set `lastAutoDecrementAt` to **3 days ago**.
- Tap «تشغيل الآن» again (step 19).
  → The quantity drops by 60 units, and the history shows «استهلاك تقديري».

### G. Out of stock, stop tracking, and messages

22. Do a stock count of **0** for an item.
    → Its badge says «نفد». After a nightly run, the clinic gets «نفد …», and the admin gets «نفد … لدى …». Tapping the admin's notification opens that clinic's inventory.
23. **Client app, stop tracking:** open that item's page and tap «إيقاف متابعة هذا الصنف» → «إيقاف المتابعة».
    → It leaves «مخزوني» and the home list. It appears under «أصناف أوقفت متابعتها» at the bottom of «مخزوني», with «استئناف المتابعة». The admin sees it marked «أوقف العميل متابعته».
24. Order that item again and deliver it.
    → It comes back to «مخزوني» by itself.
25. **Admin app, notifications tab:** tap «رسالة جديدة». Write a title and a message, and choose «جميع العملاء» or «عملاء محددون», then «إرسال».
    → «تم الإرسال إلى … عميل». The clinic's bell shows it.

### H. The admin's own screens

26. **«الرئيسية»** (dashboard):
    - Clinics that ran out (step 22) pop up once, the first time you open the dashboard in a session.
    - They also stay in the red «عملاء نفد مخزونهم» card, and tapping a clinic opens its inventory.
    - «المستودع: أصناف ناقصة أو نافدة» lists items with no usable stock, or below their minimum.
    - «دفعات قاربت على الانتهاء» lists the 40-day batch.
    - There are no money figures anywhere, by design.
27. **«الإعدادات»:** change «أحمر إذا كان المخزون يكفي أقل من (يوم)» to 5 and save.
    → «تم حفظ الإعدادات». Try setting the yellow value **below** the red one.
    → «القيمة غير مقبولة» under that field, and nothing is saved.
28. **«سجل التدقيق»:** your settings change is there as «تغيير الإعدادات», with before and after. Filter by type «الإعدادات», or by dates written as 2027-01-31.
29. **Accounts → a clinic:** its latest orders are listed under «طلبات العميل».

### I. Things worth checking for older users

30. On the phone, set **Settings → Display → Font size** to the largest, and repeat steps 7, 13 and 15.
    → Nothing is cut off. Every button is still easy to tap.
31. Put the phone in airplane mode and open a screen.
    → A plain Arabic error with «إعادة المحاولة», not a crash.

Anything that looks wrong: note the step number and what you saw, and send it to me.

---

## 3. Where the project stands

### 3.1 Phases

| Phase | What it delivers | Status |
|---|---|---|
| 0 — Foundations | Project setup, database, theme, Arabic RTL, shared packages | ✅ Done |
| 1 — Accounts | Sign-up, admin approval, login, password reset, audit log | ✅ Done |
| 2 — Catalogue & warehouse | Categories, items, batches with expiry, Arabic/English search | ✅ Done |
| 3 — Ordering | Cart, big **+**, orders, earliest-expiry allocation, cancellation, hot deals | ✅ Done |
| 4 — Inventory & estimation | My Inventory, red/yellow/green, usage estimates, auto-subtraction, stock count, admin controls | ✅ Done |
| 5 — Automation & notifications | Six nightly jobs, deduplicated alerts, expiry warnings, notification centre, admin messages | ✅ Done (push needs Firebase, 1.6) |
| — Extra | Stop tracking an item | ✅ Done |
| 6 — Admin dashboard | Dashboard (approvals, orders waiting, clinics out of stock with a popup, warehouse low/out, expiring batches, nightly run with «تشغيل الآن»), settings, audit log, a clinic's orders | ✅ Done |
| 7 — Hardening & release | RTL, theme and phone-width audits, Arabic-Indic digits, performance, full end-to-end test, deployment, backups, store release | ⬜ Next (last) |

**Overall: about 87% of the building work is done.** This is weighted by effort per phase; phases 3 and 4 were the biggest and riskiest.
- **Left:** Phase 7, about 1–1.5 working days.
- **Outside the code, on your side:** hosting, Firebase, a Google Play account, and the Play review (usually a few days).

### 3.2 Quality

- **1,183 automated tests, all passing:**
  - backend: 279 unit, 530 database and API;
  - shared packages: 135 and 44;
  - admin app: 93;
  - client app: 102.
- **Clean on every check:** type checks, the Flutter analyzer, the colour check (no hard-coded colours), the admin web build, and the "no email anywhere" check.
- **Stock is always traceable.** Every stock change, in the warehouse and on every clinic's shelf, is written to a history that the nightly check compares with the current quantities.

### 3.3 Where things are

- **Code:** `D:\PROJECTS\medical_inventory`, branch `main`, backed up to https://github.com/dantealderson/medical_inventory (public).
- **Working notes:** `docs/RESUME.md` has the full technical status and the decisions not to reopen.
- **Plans:** `docs/superpowers/plans/` (one per phase).

### 3.4 Waiting on you

1. **The app id** and **hosting** (1.7).
2. **Firebase**, if you want push notifications on phones (1.6).
3. **The "day-30 «نفد»" behaviour.**
   - When a clinic bought an item only once and never counted it, the purchase-based estimate appears after 30 days. It then subtracts the whole purchase at once, so the item shows «نفد» on day 30.
   - Today it is kept, because it errs toward warning early.
   - The alternative is to start subtracting only from the day the estimate appears.
   - A stock count (جرد) always corrects it.
