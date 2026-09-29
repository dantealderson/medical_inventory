# Resume Point

## >>> PHASE 3 PLAN READY AND VERIFIED (2026-09-29): read this first

`docs/superpowers/plans/2026-09-27-phase-3-ordering-fefo.md` is the finished Phase 3 plan: 17 tasks, header, completion checklist. It replaces the old draft.

**Every task was executed before the plan was finalised.** The run used a scratch copy of the repo and throwaway databases, which have since been dropped:
- Every expected count, expected failure message and "watch it fail" proof step was observed.
- Every "replace this" snippet matched its real file exactly once.
- The backend's real JSON responses were parsed by the Dart models.

So if a step misbehaves while executing, treat it as a real signal. Do not tune the test until it passes.

Expected totals after Phase 3: backend 184 unit + 377 e2e, api_client 98, ui_kit 37, client 71, admin 63 (**830**, up from 348).

Defects found by executing, and fixed in the plan:
- **Two CHECK constraints accepted exactly the rows they exist to reject.** A CHECK passes when its expression is NULL. An unguarded `"cancelDisposition" = 'NOT_ALLOCATED'` let a cancelled order with a NULL disposition through, and the same happened with a half-set approval. Both are now guarded with `IS NOT NULL` (plan decision 17, and `contract.md` §1), with tests for both rows.
- **The admin cancel dialog disposed its text controller while the dialog was still closing.** It is now a StatefulWidget that owns the controller.
- The confirm race's proof now fails with a 500, not a silent double allocation. `allocate` refuses a line that already holds unreleased stock (plan decision 18).

Working files, all untracked, are in `docs/superpowers/plans/phase-3-work/` (contract, scopes, fact sheets, plan parts, `progress.md`). They are kept for reference and can be deleted.

The spec edits that match the plan's decisions are done but **uncommitted**, as are this file and the new plan.

**Budget note (2026-09-29):** the user declined ultracode ("i cant afford ultracod"). The plan was written and verified inline, with no multi-agent workflow.

**Last updated:** 2026-09-29
**Branch:** `phase-0-foundations` (41 commits, `main` untouched). Uncommitted: RESUME, spec, the Phase 3 plan and `phase-3-work/`.
**Blocked on:** nothing

---

## ⚠️ Raise the effort level before Phases 3 and 4

The user asked to be reminded (2026-09-27). Phase 2 runs at normal high effort;
**Phases 3 and 4 should be run at ultracode.**

Not because the code is harder — because of how the bugs fail. Phase 2 fails
loudly: bad Arabic normalisation returns no search results, a miscategorised item
is visible on screen. Phases 3 and 4 fail silently: FEFO allocating the wrong
batch ships stock expiring in 20 days instead of 8 months and nobody notices
until it expires on a shelf; an off-by-one in the usage estimator quietly drifts
every client's inventory for weeks, filling the ledger with wrong decrements
before anyone questions the number.

Maximum effort belongs where the failure is invisible. **Do not silently start
Phase 3 at the current level — say so first.**

---

## Where we are

**Phases 0, 1 and 2 are complete and verified.** Phase 3 (ordering and FEFO) is
next — **raise the effort level first.**

| Suite | Tests |
|---|---|
| backend unit | 47 |
| backend e2e + integration | 162 |
| `packages/api_client` | 55 |
| `packages/ui_kit` | 22 |
| `admin` | 30 |
| `client` | 32 |
| **total** | **348** |

Typecheck clean, no-email gate clean, `.env` untracked.

### Phase status

| Phase | State |
|---|---|
| 0 — Foundations | ✅ complete |
| 1 — Auth & accounts | ✅ complete |
| 2 — Catalog & warehouse | ✅ complete |
| **3 — Ordering & FEFO** | **⬜ next — raise effort first** |
| 4 — Inventory & estimation | ⬜ **raise effort first** |
| 5 — Automation & notifications | ⬜ |
| 6 — Admin dashboard | ⬜ |
| 7 — Hardening | ⬜ |

Plans written so far: `2026-09-27-phase-0-foundations.md`,
`2026-09-27-phase-1-auth-accounts.md`, `2026-09-27-phase-2-catalog-warehouse.md`.

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
