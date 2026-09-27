# Medical Inventory

Monorepo: NestJS + Prisma backend, Flutter admin and client apps, shared Dart packages.

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
    npm run start:dev          # http://localhost:3000/api/v1/health

    cd ../admin  && flutter pub get && flutter run -d chrome
    cd ../client && flutter pub get && flutter run

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
