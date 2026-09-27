# Resume Point

**Last updated:** 2026-09-27
**Branch:** `phase-0-foundations` (8 commits, clean tree, `main` untouched)
**Blocked on:** Docker Desktop installation

---

## Where we are

Phase 0 (Foundations) is **code-complete**. Every file is written, typechecked, built and committed. What remains is four commands that need a running PostgreSQL.

| | Status |
|---|---|
| Backend typecheck / build / Prisma schema | clean / valid |
| Backend unit tests | 10 passing |
| `packages/ui_kit` | 22 passing |
| `packages/api_client` | 9 passing |
| `admin` / `client` | 4 + 4 passing |
| e2e + integration tests | **written, never run** (3 e2e + 7 integration) |

## To finish Phase 0

Once `docker compose version` responds:

```bash
cd D:\PROJECTS\medical_inventory
docker compose up -d
docker compose ps                      # wait for "healthy"

cd backend
npx prisma migrate dev --name init_settings
npm run db:seed                        # expect: "Seeded 15 settings."
npm test                               # 10 unit
npm run test:e2e                       # 3 e2e + 7 integration
```

Expected results:

- The migration creates a `settings` table (`key` PK, `value` JSONB, `updatedAt`). Already verified offline via `prisma migrate diff`.
- `GET /api/v1/health` → `{"status":"ok","database":"up"}`. It currently returns a 500 envelope because no database is reachable.
- All 10 DB-backed tests pass.

Then run the **Phase 0 Completion Checklist** at the bottom of
`docs/superpowers/plans/2026-09-27-phase-0-foundations.md`, and hand back to the
user for the manual gate (see "Awaiting user confirmation" below).

## The one thing that must not be changed

`DATABASE_URL` points at **port 5433**, not 5432.

A native `postgresql-x64-18` Windows service owns 5432 on this machine and the
user explicitly instructed not to use it. The container publishes 5433 so the
backend *cannot* reach the Windows install by accident. If both listened on
5432, the backend could read and write the wrong database while every test
still passed — the worst kind of bug, because nothing looks broken.

## Confirmed by the user (2026-09-27)

- **Sky blue approved** — `#4FC3F7` primary, `#0288D1` dark accent, in `packages/ui_kit/lib/src/theme/palette.dart`.
- **Arabic copy approved** — «إدارة المخزون الطبي» (admin), «المخزون الطبي» (client).

Both remain one-file edits if that changes later; the token architecture exists
precisely so it stays that way.

## Deviations from the plan, already corrected in the plan file

1. **NestJS 12 is ESM-only** → jest cannot test it. Switched to Vitest + swc (user approved). `vi.fn()`, never `jest.fn()`.
2. **TypeScript 6 needs an explicit `rootDir`** → otherwise `TS5011` before any assertion runs.
3. **Flutter 3.32 removed `package:flutter_gen`** → generated l10n lives in `lib/l10n/` as committed source; imports are relative.
4. **Prisma 7 removed `url` from the datasource** → connection config in `prisma.config.ts`, runtime client needs `@prisma/adapter-pg`. Adapters connect lazily, so the app boots with the DB down.
5. **`npm install prisma` pulls a release candidate** — its `latest` tag points at `8.0.0-rc.17` while the client's is stable `7.10.0`. Both pinned to `^7.10.0`. Re-check with `npm view prisma dist-tags` before any upgrade.

## After Phase 0

Phases 1–7 are defined in `docs/superpowers/specs/2026-09-27-medical-inventory-design.md` §15.

**Phase 1's plan is already written** — `docs/superpowers/plans/2026-09-27-phase-1-auth-accounts.md`, 10 tasks, 69 steps. It was written after Phase 0's code was committed, so its `Consumes:` table cites real signatures (`PrismaService`, `SettingsService`, `AppException`, `ERROR_CODES`, `applyAppConfig`, `ApiClient`, `ApiException`, `AppTheme`, `Breakpoints`) rather than guesses.

**Three of its ten tasks are already done** — the ones that need no database:

| Phase 1 task | Status |
|---|---|
| 2 — argon2id password hashing | ✅ 7 tests |
| 3a — audit redaction (pure function) | ✅ 11 tests |
| 8 — api_client auth, token store, refresh interceptor | ✅ 13 tests |
| 1, 3b, 4, 5, 6, 7 — schema, AuditService, register, login, guards, admin | ⛔ need Postgres |
| 9, 10 — Flutter auth screens | ⛔ depend on tasks 4–7 being runnable |

Remaining Phase 1 work resumes at **Task 1** (the `auth_accounts` migration),
which needs the same container as Phase 0.

Phases 2–7 still get their plans written immediately before they are built.
