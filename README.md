# Medical Inventory

Application written with Flutter, with Firebase and a REST API (Node.js) backend, to manage a medical supplier's inventory, and an app for its clinics to see their estimated inventory and order items with a shopping experience.

Monorepo: NestJS + Prisma backend, Flutter admin and client apps, shared Dart packages.

- **Setting it up and testing it by hand:** `docs/SETUP-AND-TESTING.md`
- **Current status and decisions:** `docs/RESUME.md`

- Design spec: `docs/superpowers/specs/2026-09-27-medical-inventory-design.md`
- Plans: `docs/superpowers/plans/`

## Layout

    backend/            NestJS + Prisma + PostgreSQL — source of truth
    admin/              Flutter — Web (responsive) / Windows
    client/             Flutter — Android / iOS
    packages/api_client Shared Dart: DTOs, HTTP, error mapping
    packages/ui_kit     Shared Dart: design tokens, theme, widgets

## Prerequisites

Docker Desktop, Node 20+, Flutter 3.32+.

## The database runs on port 5433

A native PostgreSQL service on this machine already owns **5432**. The project's
Postgres container therefore publishes **5433**, and `DATABASE_URL` points there.

This is deliberate. If both listened on 5432, the backend could silently connect
to the wrong database and every test would still pass — the worst kind of bug,
because nothing looks broken. Never change `DATABASE_URL` to 5432.

## Setup

    docker compose up -d
    cd backend && cp .env.example .env && npm install
    npx prisma migrate dev
    npm run db:seed            # settings + the first admin
    npm run start:dev          # http://localhost:3000/api/v1/health

    cd ../admin  && flutter pub get && flutter run -d chrome
    cd ../client && flutter pub get && flutter run

Set `SEED_ADMIN_PASSWORD` in `.env` before seeding, or the admin is skipped.
Re-seeding never resets an existing admin's password.

## Three databases, on purpose

| Database | Used by |
|---|---|
| `medinv` | development — the app you run |
| `medinv_test` | the e2e and integration suites |
| `medinv_shadow` | Prisma, when diffing migrations |

The suites truncate tables between tests, so they get their own database. With
a single one, `npm run test:e2e` silently deletes the seeded admin and
everything else you were working with. `test/global-setup.ts` refuses to run
if `TEST_DATABASE_URL` is unset or equals `DATABASE_URL`.

All three are created automatically on a fresh volume by `docker/init`.

## CORS

The admin app runs in a browser, so the API must allow its origin or the
browser blocks every request before it is sent — and the app can only report
«تعذر الاتصال بالخادم», which points nowhere near the real cause.

Outside production any `localhost` port is allowed, because `flutter run -d
chrome` picks a new one each launch. In production set `CORS_ORIGINS` to the
admin's real origin; an empty value there means no cross-origin access at all.
The mobile client app is unaffected — only browsers enforce this.

To confirm you are talking to the container and not the Windows install:

    docker compose exec postgres psql -U medinv -d medinv -c "select version();"

## Conventions

The app is RTL Arabic only. Colours come exclusively from
`packages/ui_kit/lib/src/theme/palette.dart` — the colour check fails the build
on any colour literal elsewhere. User-facing strings live in `.arb` files.

Run the colour check over any Dart package before committing:

    cd packages/ui_kit && dart run bin/check_colors.dart lib
    cd ../../admin     && dart run ui_kit:check_colors lib
    cd ../client       && dart run ui_kit:check_colors lib
