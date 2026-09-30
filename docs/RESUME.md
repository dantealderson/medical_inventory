# Resume Point

## >>> PHASE 6 COMPLETE (2026-09-30). Phase 7 (hardening and release) is next

**For the user:** `docs/SETUP-AND-TESTING.md` covers what to set up, how to test by hand, and current progress.

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
**Blocked on:** nothing for Phase 7's code. Deployment needs the user's hosting and app-id decisions (`docs/SETUP-AND-TESTING.md` 1.7), and push needs the Firebase hand-off below.

### Push notifications: what only you can do (FCM hand-off)

1. Create a Firebase project and add an Android app (and iOS later), with package id as in `client/android/app/build.gradle*`.
2. On the server, put the service-account JSON (Project settings → Service accounts → Generate key) on one line in `FIREBASE_SERVICE_ACCOUNT_JSON`. The backend switches from "no push" to FCM automatically.
3. In `client`, run `flutterfire configure`. Then a short task adds `firebase_messaging` and registers the token through the existing `POST /devices`.

Until then, every notification still reaches the in-app centre.

---

## Where we are

**Phases 0–6 are complete and verified.** Phase 7 (hardening and release) is next.

| Suite | Tests |
|---|---|
| backend unit | 279 |
| backend e2e + integration | 530 |
| `packages/api_client` | 135 |
| `packages/ui_kit` | 44 |
| `admin` | 93 |
| `client` | 102 |
| **total** | **1183** |

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
