# Resume Point

## >>> GO-LIVE PLAN AGREED (2026-10-01). The user is doing their hands-on steps 1–9; mine are 10–19

**Decided by the user (2026-10-01):**
- App id **`iq.medsupply.app`**; app name and business name **«مخزون العيادة»**; icon made by me (teal, white medicine box, green cross; source `client/store/icon.svg`, Play icon `client/store/icon-512.png`).
- Day-30 «نفد»: **kept** as the spec says. Green (the design pick) is **final**; it replaces the spec's white and sky blue.
- Catalogue size unknown, so **no Excel import** for now.
- Google Play: a **personal** account. New personal accounts need a closed test with **12 testers for 14 days** before going public; the heavy testing happens inside that window.

**Done on 2026-10-01:**
- **App id changed** on Android (`namespace`, `applicationId`, `MainActivity` under `kotlin/iq/medsupply/app`) and iOS (bundle id, display name).
- **Firebase project `iq-medsupply-app`** ("Medical Supply"), created with the user's Firebase CLI login. `flutterfire configure` registered the Android app: `google-services.json`, `lib/firebase_options.dart`, the `google-services` Gradle plugin, and `firebase_core` in the client. Nothing calls Firebase yet (step 12).
- **Play upload key** in `C:\Users\ACER PC\medinv-signing\` (`upload-keystore.jks` + `key.properties`, alias `upload`), outside the repo. `client/android/key.properties` (untracked) points at it. Without that file, as on GitHub, release builds use the debug key.
- **Push (step 12), built:** `core/push.dart` (`PushController`, `PushMessaging` so tests fake Firebase) and `core/firebase_push.dart` (Android only; null elsewhere or if Firebase fails, so the app always starts).
  - Signing in asks for permission (Android 13+) and registers the token (`POST /devices`, platform `android`); a refreshed token is registered too.
  - Logout first unregisters it (`AuthController.beforeLogout`, set by push to avoid a provider cycle; 5 s cap).
  - A tapped push opens its order or item, as the centre does, and marks it read; one that started the app waits for the session check. One arriving while the app is open shows its title in a bar with «عرض» and reloads the bell.
  - Android: the «التنبيهات» channel (`alerts`, high importance) made in `MainActivity`, a white status-bar icon `ic_stat_notify`, teal accent. The server sends `android.priority: high`.
  - Not yet seen on a real phone: that needs the user's step 5 (the service-account key on Render).
- `flutter build appbundle` works and is signed `CN=Medical Supply, C=IQ`. Flutter reports "failed to strip debug symbols" although the toolchain is complete; the bundle is still produced. Look at it before the first Play upload.

**The plan, in order:**
- **The user, now:** 1 decisions (done) · 2 Play account · 3 Neon · 4 Render · 5 Firebase service-account key into Render as `FIREBASE_SERVICE_ACCOUNT_JSON` · 6 GitHub Pages + `API_BASE_URL` · 7 try it on a phone · 8 back up `medinv-signing` · 9 find 12+ testers.
- **Me:** 10 app id, name, icon (done) · 11 signing + .aab (done) · 12 push (built; untested on a phone until step 5) · 13 fix what breaks online · 14 daily database backups · 15 account deletion in the app and on a web page (a Play rule) · 16 privacy policy on GitHub Pages · 17 the redesign (`design-canvas` memory) with IQD prices and the two Phase 4 minors · 18 a review of the Phase 4 stock and estimate logic · 19 Excel import only if needed.
- **Later:** 20 the user's UI comments · 21 the user checks the privacy policy · 22 Play closed test and listing · 23 2–3 days of heavy testing · 24 fixes and re-test · 25 real server and domain · 26 the real catalogue on a clean database · 27 apply for production and publish.

**Earlier work order (2026-10-01), superseded by the plan above:**
1. Pictures (Phase 10), which is done.
2. Hosting prep (Phase 9, up to the accounts only the user can create), which is done.
3. My own UI pass: the spec's audits plus a clean-up for older users.
4. The user's UI comments.

Phase 8 (Firebase) and manual testing wait until the user has time.

**For the user:** `docs/SETUP-AND-TESTING.md` covers what to set up, how to test by hand, and current progress.

**The roadmap, in the user's order (2026-09-30):**
1. Everything works. This is Phase 7, done.
2. **Phase 8: Firebase push.**
   - Needs the user to create a Firebase project and choose the real app id; `com.example.client` is a placeholder.
   - See the FCM hand-off below.
3. **Phase 9: temporary free hosting**, to test from anywhere.
   - A backend Docker image on a free host plus free Postgres (for example Render with Neon).
   - Postgres kept on UTC.
   - A demo-data seed for the fresh database.
   - The admin web hosted as static files; the client built with the hosted `API_BASE_URL`.
4. **Phase 10: item pictures.** Done; see below.
5. **Phase 11: UI and looks.**
   - The user has many UI comments, deliberately held until here.
   - This phase also takes the spec's RTL, theme and responsive audits, the large-text check, and Arabic-Indic digits.

**Phase 9 prep (hosting).** Free test hosting, ready for the user's accounts. The steps are in `docs/HOSTING.md`.
- **`backend/Dockerfile`:** node 24 slim with OpenSSL. It keeps the dev dependencies, because `prisma migrate deploy` and ts-node run at every start. `npm ci --foreground-scripts`.
- **`backend/scripts/start.sh`,** every step safe to repeat:
  1. `migrate deploy`;
  2. `db:seed`, which creates the admin once;
  3. with `DEMO_DATA=true`, the demo data (it only fills an empty catalogue);
  4. `node dist/main`.
- **`prisma.config.ts`:** the shadow database is optional, because `env()` threw at start on a host without it.
- **Demo data:** `src/demo/demo-data.ts` (`seedDemo`) and `npm run db:seed:demo` (after `npm run build`).
  - Everything goes through the real API; only history is backdated, as in the full-loop test.
  - It adds 13 items in 3 sections, 14 batches, `clinic_alnoor` (red, yellow, green, and an order to confirm), `clinic_alshifa`, and `lab_alamal` (pending), then runs the nightly jobs.
  - It refuses a database that already has a catalogue.
- **`render.yaml`:** the backend as a free Docker web service.
  - `DATABASE_URL` points at a free **Neon** database; Render's free Postgres expires after 30 days.
  - The JWT secrets are generated.
  - `CORS_ORIGINS=https://dantealderson.github.io`.
- **`.github/workflows/apps.yml`:**
  - builds the admin web onto **GitHub Pages** (`--base-href /medical_inventory/`);
  - builds a release APK onto the `test-build` pre-release, at a fixed download link;
  - both use the repository variable `API_BASE_URL`, and both are skipped until it is set.
- **Free-tier limits:** the server sleeps after 15 minutes (the app's retry screen covers it), and the nightly jobs miss nights it is asleep (the dashboard's «تشغيل الآن» covers that).

**Phase 10 (pictures).** The plan is `docs/superpowers/plans/2026-10-01-phase-10-item-pictures.md`.
- **Stored in Postgres (`media_files`), not on disk.**
  - Free hosts wipe their disk on restart, and a table is in every backup.
  - This supersedes the spec's "VPS filesystem".
  - `UPLOAD_DIR` and `/uploads` are gone.
- **Served publicly** at `GET /api/v1/media/<id>.webp`, with the thumbnail at `<id>.thumb.webp`.
  - Cached for a year, because every upload gets a new id.
  - Full size fits 1200 px and the thumbnail 300 px, never enlarged. `rotate()` applies the EXIF orientation of phone photos.
- **One request uploads and attaches:**
  - `PUT` and `DELETE` on `/admin/items/:id/image` and `/admin/categories/:id/image`;
  - the picture being replaced is deleted, and so is a deleted category's;
  - audited with `imageUrl` before and after.
- **Admin:** a thumbnail on each item and category row, plus «إضافة صورة» / «تغيير الصورة» / «حذف الصورة». Uses `file_picker` via `picturePickerProvider`.
- **Client:** `ItemPicture`, showing the thumbnail in item cards, category tiles, hot deals and cart lines, and the full size on the item's page, with a placeholder when missing.
- **Dart helpers:** `thumbnailOf` and `mediaUri` in `api_client`.

**Phase 7 (everything works).** The plan is `docs/superpowers/plans/2026-09-30-phase-7-functional-hardening.md`. It was re-scoped from "hardening" after the user's own test run, and fixed:
- **Admin:**
  - A red `_dependents.isEmpty` screen after every save. Four dialogs disposed their text controllers while still closing, and a browser leaves the last word "composing".
  - Tabs switch instantly (a `PageTransitionsBuilder` with zero duration).
  - A page loaded while the server is down keeps the session and offers a retry.
- **Client, sign-in:**
  - Log out is in a «⋮» menu and asks first. It used to be an icon right beside the cart.
  - No signal at startup keeps the session.
  - «إبقني مسجّلاً الدخول» (`SessionTokenStore`: tokens in memory only when unticked).
  - A session the server ended (suspend, password reset) returns to login and says so.
- **Client, navigation:**
  - Search happens in place on home; the first letter used to jump to a screen with no search box.
  - Pages fade in 200 ms.
  - The phone's back button goes to the page's parent. `BackArrow` handles both the app-bar arrow and the phone's button; it used to close the app from any page.
  - A stock count with numbers typed asks before being thrown away.
  - A category whose tree failed to load offers a retry instead of spinning forever.
- **Both apps: fresh data.**
  - Lists are `autoDispose`, so each visit fetches again.
  - Everything others change reloads when the app, or the admin's browser tab, comes back to the foreground (`refreshServerData`).
- **Tooling:** `client/run-on-phone.cmd` runs the client over USB on any network and keeps `adb reverse` alive.

**Phase 6 (admin dashboard).** The plan is `docs/superpowers/plans/2026-09-30-phase-6-admin-dashboard.md`. It added:
- **The dashboard as the admin's home (`/`):**
  - pending approvals, and orders awaiting confirmation;
  - clinics out of stock, as a red card plus a popup once per session;
  - warehouse items OUT (no unexpired stock) or LOW (below the item minimum);
  - expiring batches, and expired ones still in stock;
  - the last nightly run, with «تشغيل الآن».
- **Settings:**
  - validated per key, plus cross-field rules (yellow > red; min purchase ≤ window; shelf life ≥ 0);
  - audited as `SETTINGS_CHANGED`;
  - the time zone is read-only.
- **The audit log:** filters by entity, actor and whole Baghdad days (`startOfBusinessDay`).
- **The account page** lists the clinic's latest orders.
- **Moved:** accounts now live at `/accounts`; admin tests reach them with `openAccountsTab`.

**Stop tracking (done after Phase 5).**
- A clinic can hide an item it no longer uses: it leaves My Inventory, alerts, expiry warnings and auto-decrement. The column is `trackingStoppedAt`.
- The clinic resumes it from a list at the bottom of My Inventory; a new delivery resumes it by itself, with the baseline reset to that delivery.
- The admin still sees the item, marked.

Phase 5 (automation and notifications) is built on `phase-5-automation-notifications`, branched from `main` (which holds Phases 0–4). The plan is `docs/superpowers/plans/2026-09-30-phase-5-automation-notifications.md`.

What exists now:
- **Every notification is a row first.**
  - Order and account notifications are written in the same transaction as the event they announce.
  - Push happens after the commit, best-effort, and never fails a request or a job.
- **The six nightly jobs run at 00:30 Baghdad (§8),** in order: auto-decrement, recompute estimates, stock alerts, expiry warnings, hot-deals rebuild, ledger check.
  - Each job is logged in `job_runs`, and a failing job never stops the next one.
  - A Postgres advisory lock means two runs never overlap.
  - The admin can trigger a run with `POST /admin/jobs/nightly`.
- **Stock alerts are deduplicated per (type, clinic, item) over `alerts.repeatAfterDays`.** Running out fires at once even inside a low-stock window. Clinics that run out also alert the admins.
- **The admin can broadcast** to all active clinics or chosen ones.
- **The client app has a bell with an unread count and a notification centre.** An unread notification says «جديد»; tapping one marks it read and opens the order or the item.
- **The admin app has a notifications tab** (inbox plus composer).

**Last updated:** 2026-09-30
**Branch:** `main`, pushed to `origin` = https://github.com/dantealderson/medical_inventory (**public**, by the user's choice, 2026-09-30).
**Blocked on:** Phase 8 needs the user's Firebase project and app id (the hand-off below). Phase 9 needs a hosting account (`docs/SETUP-AND-TESTING.md` 1.7).

### Push notifications: what only you can do (FCM hand-off)

1. Create a Firebase project and add an Android app (and iOS later), with package id as in `client/android/app/build.gradle*`.
2. On the server, put the service-account JSON (Project settings → Service accounts → Generate key) on one line in `FIREBASE_SERVICE_ACCOUNT_JSON`. The backend switches from "no push" to FCM automatically.
3. In `client`, run `flutterfire configure`. Then a short task adds `firebase_messaging` and registers the token through the existing `POST /devices`.

Until then, every notification still reaches the in-app centre.

---

## Where we are

**Phases 0–7 are complete and verified.** Phase 8 (Firebase push) is next.

| Suite | Tests |
|---|---|
| backend unit | 279 |
| backend e2e + integration | 541 |
| `packages/api_client` | 141 |
| `packages/ui_kit` | 44 |
| `admin` | 107 |
| `client` | 132 |
| **total** | **1244** |

The typecheck, `flutter analyze`, `check_colors`, the admin web build and the no-email gate are all clean, and `.env` is untracked. The backend e2e suites need Docker (Postgres on 5433). `JOBS_ENABLED=false` in tests.

### Phase 5 decisions worth not relitigating

- **Notification rows join the event's transaction; push runs after the commit.** A rolled-back confirm never announces itself, and an FCM outage never fails an order.
- **Alert levels.** qty 0 → `OUT_OF_STOCK`, plus `CLIENT_OUT_OF_STOCK` to the admins. RED → `LOW_STOCK`. YELLOW, GREEN and UNKNOWN → nothing. One dedupe key per level, so "worsening" fires at once. Only ACTIVE clinics and active items.
- **Expiry warnings go out once per recipient and batch,** only for batches not yet expired and inside `expiry.warnDaysAhead`.
- **The nightly lock** is `pg_try_advisory_xact_lock(5000001)`, held by one long transaction for the whole run. A session lock through a pool could be released on another connection.
- **Jobs create notifications with `createdAt = now`,** so dedupe windows are measured in the job's own time.
- **Firebase is imported only when configured.** No credentials means `NoopPushSender`.

### Phase 4 decisions worth not relitigating

- **"Day" means a Baghdad business date.** Elapsed days and estimate windows are `diffDaysIso(businessDateOf(…))` differences, never differences of UTC instants.
- **Rates and carries are `Prisma.Decimal`.** A decrement never uses a float: 10 days at 0.3 is exactly 3.
- **`UsageEstimate.ratePerDay` is NULL exactly when the source is NONE** (a CHECK). Stored as 0, "no data" would read as "uses nothing", a false green. Confidence is an enum, NULL for MANUAL and NONE.
- **An admin override wins at once,** in the views and in auto-decrement, without waiting for a recompute.
- **An empty shelf moves the baseline** (`lastAutoDecrementAt = now`, carry 0), so a restock is never charged for the empty days. Clamping at zero drops the carry.
- **Re-enabling auto-decrement resets the baseline,** so the disabled period is never subtracted.
- **A stock count resets carry and `lastAutoDecrementAt`** in the same transaction (§7.5). A count-down depletes holdings earliest-expiry-first. A count-up leaves holdings alone, so the invariant is **ledger == cache and 0 ≤ Σ holdings ≤ cache** (`expectClientShelfConsistent`). Phase 3 suites keep the strict equality helper.
- **Lock order on a clinic's shelf:** holdings (by batchId), then item rows (by itemId), everywhere (`lockShelf`).
- **The status is computed at read time with Decimal comparisons,** never stored. Precedence: RED, YELLOW, GREEN, UNKNOWN. A rate of 0 means infinite cover.
- **The per-clinic minimum is entered in whole boxes,** like the item minimum.

### Phase 4 audience-driven choices (see "Who uses this" below)

- **Home:** a full-width «مخزوني» button, and the red items as at most 2 rows with a 56 dp **+**, plus «عرض الكل» (not a sideways strip).
- **Badges:** always a word and an icon as well as a colour.
- **The count screen:** nothing pre-filled, a pinned «حفظ الجرد» button, and a confirmation first.
- **Large text:** every new client screen is tested at 390 px with 1.5× text.

### Phase 4: open items

- **Needs your decision — the day-30 "نفد".** A purchase-based estimate first appears 30 days after a clinic's first delivery of an item. The spec's catch-up then subtracts exactly what was delivered in that window, so an item bought once reads «نفد» on day 30, by construction. This is kept as the spec says, because it errs toward warning. The alternative is to start subtracting only from the day the estimate appears, which risks under-warning.
- **Done — items the clinic no longer uses:** the "stop tracking" option, see the top section.
- **Fixed in Phase 5:** one row's failure no longer stops that night's auto-decrement for the rest. Rows are isolated and counted as `failed`.
- **Minor:** item history shows nothing until the item's card loads. The home red-items strip refreshes per visit, not live.
- **The final review was a self-review.** The fresh reviewer was stopped before it reported.

### Phase status

| Phase | State |
|---|---|
| 0 — Foundations | ✅ complete |
| 1 — Auth & accounts | ✅ complete |
| 2 — Catalog & warehouse | ✅ complete |
| 3 — Ordering & FEFO | ✅ complete |
| 4 — Inventory & estimation | ✅ complete |
| 5 — Automation & notifications | ✅ complete |
| 6 — Admin dashboard | ✅ complete |
| **7 — Hardening** | **⬜ next** |

Plans written so far: phases 0–3 (`docs/superpowers/plans/2026-09-27-phase-*.md`) phase 4 and phase 5 (`docs/superpowers/plans/2026-09-30-phase-*.md`).
Phase 3's planning working files are in `docs/superpowers/plans/phase-3-work/` (untracked, safe to delete).

### Phase 3 decisions worth not relitigating

- **Only `AllocationService` moves warehouse stock for orders.** It writes the decrement, the negative `ORDER_OUT`, the allocation row and `qtyUnitsFulfilled` together.
- **One lock statement covers every candidate batch** of every item in the order: `ORDER BY "itemId","expiryDate","receivedAt",id`, `FOR NO KEY UPDATE`, with **no** `qtyUnitsRemaining > 0` filter. The global order prevents deadlocks, the lock strength lets deliveries' FK checks through, and the missing filter means a batch being refilled is waited for rather than skipped.
- **Every order transition locks the order row first** (`lockOrder`) and validates against the status that lock returns. A double-click then gets one effect and one 409.
- **`release()` stamps `releasedAt … IS NULL RETURNING` and never deletes.** `WRITTEN_OFF` writes no movement.
- **The shelf-life cutoff is a Baghdad calendar date string**, computed before the transaction and compared with `::date`.
- **Every CHECK on a nullable column has an `IS NOT NULL` guard.** A CHECK passes when its expression is NULL; two constraints first accepted exactly the rows they exist to reject.
- **Tests reset the database with `resetDb()`**, one TRUNCATE over every table. Never go back to `deleteMany` chains: the RESTRICT FKs break them.
- **Money is `Prisma.Decimal`**, emitted as `toFixed(2)`. `lineTotal` is the billed amount, and `totalAmount = Σ lineTotal`.
- **The client's per-user providers watch the signed-in user id.** Per-visit data (availability, order detail and history) is auto-disposed.

### Who uses this — read before any UI or triage decision

The client app's users are **clinic staff aged 30 and over, many of them older** (user, 2026-09-30):
- **Buttons and screens:** big buttons, simple screens and plain wording. Tap targets are 48 dp or more; primary actions 56–64 dp. Never clamp the phone's text size.
- **Triage:** fix what a real person meets in daily use, such as double taps, slow networks, long lists and confusing messages. Do **not** spend effort on two-devices-within-milliseconds races or hand-edited DB values.
- **Phase 7:** add a large-text (1.3×–1.5×) overflow check of the client screens at 390 px.

### Phase 3 reviewer Minors deliberately not fixed (unrealistic for these users)

- `setLine`/`removeLine` don't take the cart-row lock, so an edit from another device mid-placement can be lost (a millisecond window).
- `creditDelivery` writes `now()` into timestamps. Pass `${new Date()}` as `release()` does. This only matters if the DB TimeZone isn't UTC, so **Phase 7 deployment must keep Postgres on UTC**.
- Placement doesn't re-check `MAX_LINE_UNITS` after a re-box of an item that has no batches.
- The five-tap cart e2e test and allocation test (d) are smoke tests, not barrier-deterministic.
- Code comments cite the contract's D1–D20 numbering, not the plan's decision-table numbering.
- Guard `minShelfLifeDays >= 0` in `cutoffFor`, or in Phase 6's settings validation.

### Phase 2 decisions worth not relitigating

- **`searchText` is maintained by a TRIGGER, not a generated column.** Prisma
  cannot model a generated column — it reads the expression as a `DEFAULT` and
  emits `ALTER COLUMN … DROP DEFAULT` on every diff, which makes
  `prisma migrate dev` stop at an interactive drift prompt and hang. That
  happened. A trigger is invisible to Prisma's column introspection.
- **The normalisation function is versioned** (`search_normalize_v1`) because
  PostgreSQL 16 has no `ALTER COLUMN … SET EXPRESSION`.
- **`expiryDate` is `@db.Date`.** As a timestamp, UTC+3 shifts every expiry a
  day earlier.
- **Batch identity is `(item, batchNumber, expiryDate)`** — the same lot
  legitimately arrives twice with different expiries.
- **`unitsPerBox` freezes once a batch exists**, because `minQtyUnits` is
  stored in units and would silently reinterpret.
- **Intake writes the batch and its `PURCHASE_IN` movement in one
  transaction.** `StockMovement` therefore lives in Phase 2, not Phase 4.
- **Five CHECK constraints have their own tests** — Prisma cannot see them, so
  a later migrate could drop them while reporting success.

---

## Running it

```bash
cd D:\PROJECTS\medical_inventory
docker compose up -d
cd backend && npm run start:dev

cd admin  && flutter run -d chrome     # admin is web-only
cd client && flutter run -d chrome     # or an android device/emulator
```

Dev admin: the username and password are `SEED_ADMIN_USERNAME` / `SEED_ADMIN_PASSWORD` in `backend/.env` (local only, never committed).

Docker Desktop is installed **per-user**, so its binary is missing from a shell
whose PATH was captured before installation:

```bash
export PATH="$PATH:/c/Users/ACER PC/AppData/Local/Programs/DockerDesktop/resources/bin"
```

---

## Things that will bite if forgotten

**Postgres is on port 5433, not 5432.** A native `postgresql-x64-18` Windows
service owns 5432 and the user asked not to use it. If both listened on 5432 the
backend could read and write the wrong database while every test still passed.
Verified: 5433 is the container (v16), 5432 rejects the `medinv` credentials.

**Three databases, on purpose.** `medinv` (development), `medinv_test` (the e2e
and integration suites, which truncate tables), `medinv_shadow` (Prisma migration
diffs). With a single database, `npm run test:e2e` silently deletes the seeded
admin. `test/global-setup.ts` refuses to run if `TEST_DATABASE_URL` is unset or
equals `DATABASE_URL`. All three are created on a fresh volume by `docker/init`.

**CORS is required for the admin**, which is web-only — without it the browser
blocks every request and the app can only report «تعذر الاتصال بالخادم». Any
localhost origin is allowed outside production; production needs `CORS_ORIGINS`.

**The client's API URL is platform-dependent.** `10.0.2.2` is the Android
emulator's host alias and is meaningless on web or desktop. A *physical* Android
device needs the machine's LAN address via
`--dart-define=API_BASE_URL=http://192.168.1.x:3000/api/v1`.

---

## Confirmed by the user

- **Sky blue approved** — `#4FC3F7` primary, `#0288D1` dark accent, in
  `packages/ui_kit/lib/src/theme/palette.dart`.
- **Arabic copy approved** — «إدارة المخزون الطبي» (admin), «المخزون الطبي» (client).

---

## Deviations from the original plans, all corrected in the plan files

1. **NestJS 12 is ESM-only** → jest cannot test it. Uses Vitest + swc; `vi.fn()`, never `jest.fn()`.
2. **TypeScript 6 needs an explicit `rootDir`** → otherwise `TS5011` before any assertion runs.
3. **Flutter 3.32 removed `package:flutter_gen`** → generated l10n lives in `lib/l10n/` as committed source.
4. **Prisma 7 removed `url` from the datasource** → config in `prisma.config.ts`, client needs `@prisma/adapter-pg`. Adapters connect lazily, so the app boots with the DB down.
5. **`npm install prisma` pulls a release candidate** — its `latest` tag points at an `8.0.0-rc`. Both packages pinned to `^7.10.0`.
6. **Riverpod 3 removed `StateProvider`** → use `NotifierProvider`.
7. **swc does not typecheck** → tests can pass while `tsc --noEmit` fails. Run the typecheck separately.
