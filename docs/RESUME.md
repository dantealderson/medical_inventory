# Resume Point

## >>> PHASE 3 COMPLETE (2026-09-30). Phase 4 is next: give the reminder below first

Phase 3 (ordering and FEFO) is built, reviewed and fixed, on `phase-0-foundations` as 20 commits after `1b9eabe` (the plan commit). The plan is `docs/superpowers/plans/2026-09-27-phase-3-ordering-fefo.md`.

How it was done:
- **Inline, with no multi-agent workflow.** The user declined ultracode ("i cant afford ultracod").
- **The plan was verified by running it** in a scratch copy before it was finalised.
- **It was executed task by task under TDD.** Each test was watched failing, each "remove the lock and watch the test fail" proof was run, and the result is committed per task.
- **One fresh reviewer (Opus) checked the whole range** and found 0 Critical and 2 Important issues, both fixed with RED→GREEN tests in `0483303`:
  - Rapid **+** taps were dropped while a request was in flight. Now five taps give five boxes.
  - Item availability and order status stayed cached for the whole session. They now refetch on every visit.
- **Nine Minor findings are deferred.** They are listed in "Deferred from Phase 3" below.

**Last updated:** 2026-09-30
**Branch:** `phase-0-foundations` (`main` untouched)
**Blocked on:** nothing

---

## ⚠️ Raise the effort level before Phase 4

The user asked to be reminded (2026-09-27): **Phases 3 and 4 should be run at ultracode.**

Not because the code is harder, but because of how the bugs fail. An off-by-one in the usage estimator quietly drifts every client's inventory for weeks, filling the ledger with wrong decrements before anyone questions the number.

**Do not silently start Phase 4 at the current level. Say so first.** The user is budget-constrained, though. For Phase 3 they chose inline work at the current effort, so offer that as a first-class option too. For Phase 3 the rigour went into a plan verified by execution, watched-failing proofs, and one final reviewer.

---

## Where we are

**Phases 0–3 are complete and verified.** Phase 4 (inventory and estimation) is next. **Give the reminder above first.**

| Suite | Tests |
|---|---|
| backend unit | 184 |
| backend e2e + integration | 377 |
| `packages/api_client` | 98 |
| `packages/ui_kit` | 37 |
| `admin` | 63 |
| `client` | 74 |
| **total** | **833** |

The typecheck, `flutter analyze`, `check_colors` and no-email gates are clean; `.env` is untracked. The backend e2e suites need Docker (Postgres on 5433).

### Phase status

| Phase | State |
|---|---|
| 0 — Foundations | ✅ complete |
| 1 — Auth & accounts | ✅ complete |
| 2 — Catalog & warehouse | ✅ complete |
| 3 — Ordering & FEFO | ✅ complete |
| **4 — Inventory & estimation** | **⬜ next — give the effort reminder first** |
| 5 — Automation & notifications | ⬜ |
| 6 — Admin dashboard | ⬜ |
| 7 — Hardening | ⬜ |

Plans written so far: phases 0, 1, 2 and 3 (`docs/superpowers/plans/2026-09-27-phase-*.md`).
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

### Deferred from Phase 3 (reviewer Minors, not yet fixed)

- Confirming with a shortfall shows only «تم تأكيد الطلب». Add a distinct "confirmed with a shortfall" message.
- Cart stepper: a quick second tap can re-send the same absolute quantity. Await the cart refetch, or seed it from the returned `Cart`.
- `setLine`/`removeLine` don't take the cart-row lock, so an edit from another device mid-placement can be lost (a millisecond window).
- `creditDelivery` writes `now()` into timestamps. Pass `${new Date()}` as `release()` does. This only matters if the DB TimeZone isn't UTC.
- Placement doesn't re-check `MAX_LINE_UNITS` after a re-box of an item that has no batches.
- The five-tap cart e2e test and allocation test (d) are smoke tests, not barrier-deterministic.
- Code comments cite the contract's D1–D20 numbering, not the plan's decision-table numbering.
- The admin order list stops at 50, with no paging for delivered, cancelled or all orders.
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

Dev admin: `admin` / `devadminpassword1` (from `.env`, local only).

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
