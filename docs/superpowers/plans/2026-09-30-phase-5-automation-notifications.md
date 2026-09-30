# Phase 5 — Automation & Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The system tells people things without being asked:
- A clinic hears when an item runs low or out, when a batch it holds is about to expire, and when its orders move.
- The admin hears about new orders, clinics that ran out, and warehouse batches nearing expiry.
- The admin can message all clinics or chosen ones.
- Every night, in the right order, the system:
  - subtracts estimated usage;
  - recomputes estimates;
  - raises alerts;
  - warns about expiry;
  - rebuilds hot deals;
  - checks that every cache still agrees with the ledger.

**Architecture:**
- `src/notifications/`: every notification is a `Notification` row first, and push is a best-effort layer on top (`PushSender`; FCM when configured, a no-op otherwise).
- `src/alerts/`: the stock-alert and expiry-warning jobs.
- `src/jobs/`: the nightly runner. It uses `@nestjs/schedule`, logs each job as a `JobRun` row, lets no failed job stop the others, and takes a Postgres advisory lock so two runs never overlap.
- Order and account transitions write their notification rows inside their own transactions.
- Client: a bell with an unread count, and a notification centre that deep-links.
- Admin: an inbox plus a broadcast composer with a recipient picker.

**Tech Stack:** as Phase 4, plus `@nestjs/schedule` and `firebase-admin`.

**Spec:** `docs/superpowers/specs/2026-09-27-medical-inventory-design.md`:
- §6 (`Notification`, `DeviceToken`)
- §7.6 (RED drives the alert)
- §7.8 (notifications, dedupe)
- §8 (jobs, order, idempotency, run log)
- §9 (`alerts.repeatAfterDays`=7, `expiry.warnDaysAhead`=60)
- §12 (notification centre, admin compose)

Requirements **5, 13**.

**Execution:** as Phase 4. The plan carries decisions, interfaces and exact test cases; code is written once, test-first; deviations are ledgered.

---

## Global Constraints

- Everything from Phases 0–4 still applies. This includes the audience rules: large targets, words not just colours, plain Arabic, and screens tested at 390 px with 1.5× text.
- **A notification is a row first.**
  - It is written in the same transaction as the event it announces, wherever that event has a transaction, so a rolled-back confirmation never tells a clinic it was confirmed.
  - Push happens after the commit, best-effort. A push failure is logged and never fails the request or the job.
- **Notification text is Arabic, composed on the server.** It uses the item's own unit words (`formatQuantityAr`), and the apps show it as sent.
- **Jobs take `now: Date`** and are idempotent, so a second run the same night writes nothing new.
- **`JOBS_ENABLED=false` in tests.** The scheduler is never armed in a test process; tests call the runner directly.
- **Push is unavailable without Firebase credentials.** Without `FIREBASE_SERVICE_ACCOUNT_JSON`, the system runs with `NoopPushSender`. Registering the client app with FCM needs a Firebase project and `flutterfire configure`, which only the user can do; that part is deferred and recorded, not faked.

## Review Focus

1. **A clinic that sits red for a month** gets one alert a week, not thirty. When the item runs out completely, it gets a new alert at once.
2. **A failed push** (no Firebase, a dead token) never loses the notification and never blocks the order action or the job.
3. **One failing job, or one failing row,** does not stop the rest of the night.
4. **Running the nightly jobs twice in one night** changes nothing the second time.
5. **An older user taps a notification** and lands on the right screen (the order, or the item in My Inventory), and it is marked read.

## Decisions (do not relitigate)

| # | Decision | The failure it prevents |
|---|---|---|
| 1 | Notification rows are written in the event's own transaction; push runs after the commit and catches everything. | "Your order was confirmed" for a confirmation that rolled back. A push outage failing a delivery. |
| 2 | Alert levels. qty 0 → `OUT_OF_STOCK` to the clinic, plus `CLIENT_OUT_OF_STOCK` to every active admin. RED with qty > 0 → `LOW_STOCK`. YELLOW, GREEN and UNKNOWN → none. The dedupe key is `${type}:${clientId}:${itemId}`: suppressed if one exists with `createdAt > now − repeatAfterDays`. Each level has its own key, so worsening (RED → zero) fires at once, as §7.8 requires. YELLOW never alerts, so YELLOW → RED is always a first alert. Only ACTIVE clinics, and only active items (a deactivated item's **+** is disabled, so "order now" would be a lie). | Thirty identical alerts; a muted app (§7.8). |
| 3 | `EXPIRY_WARNING` fires once per (recipient, batch), ever. The window is `[today, today + warnDaysAhead]`. Warehouse batches with stock go to every active admin; held batches go to the holding clinic. Already-expired batches are not warned (the admin's expiry report lists them). | Eight weekly reminders for one batch. |
| 4 | `PushSender` is an interface. `FcmPushSender` (`firebase-admin`, `sendEachForMulticast`) is used when `FIREBASE_SERVICE_ACCOUNT_JSON` is set, and `NoopPushSender` otherwise. Tokens FCM reports as unregistered or invalid are deleted. | Pushing to dead tokens forever. |
| 5 | The nightly runner runs at 00:30 in `business.timezone` (read at boot), in §8 order. Each job is a `JobRun` (RUNNING → SUCCEEDED/FAILED, with a summary or an error), and a failed job never stops the next. Postgres advisory lock `pg_try_advisory_lock(5_000_001)` means a second concurrent run is refused (409 `JOBS_ALREADY_RUNNING`). The admin can trigger a run and list recent runs. | Two overlapping runs racing each other; a silent night with no record. |
| 6 | `AutoDecrementService.run` isolates rows: a failed row is logged and counted as `failed`, and the rest continue (Phase 4 minor). | One bad row skipping every clinic that night. |
| 7 | `ledger-assert` checks warehouse batches (ledger == cache) and clinic shelves (ledger == cache, 0 ≤ Σ holdings ≤ cache). It reports drift (a count plus the first 20) in the run summary and never "fixes" anything. | A rebuild quietly overwriting real stock (§5). |
| 8 | Broadcasts go to ACTIVE clinics only. The audience is `ALL` or explicit `clientIds`. Unknown or non-client ids → 400, listing them. One row per recipient. Title 1..100 characters, body 1..1000. | A message to a suspended or unknown account. |
| 9 | Order events. The clinic gets CONFIRMED, OUT_FOR_DELIVERY, DELIVERED, and CANCELLED when an admin cancels. Every active admin gets ORDER_PLACED, and ORDER_CANCELLED when the clinic cancels. Account events: ACCOUNT_APPROVED and ACCOUNT_REJECTED go to the account. | The person who acted being told what they just did. |
| 10 | The payload is a deep-link object, `{ "orderId": … }` or `{ "itemId": … }`, or null. | Apps parsing Arabic text to decide where to go. |
| 11 | The client shows the unread count on the home bell, refreshed on each visit to home and after reading. There is no background polling. | A battery-draining timer on older phones. |

---

## File structure

**Backend — create:**
- `prisma/migrations/<ts>_notifications_jobs/migration.sql`
- `src/common/quantity-format.ts`: `formatQuantityAr`.
- `src/notifications/`:
  - `notifications.module.ts`, `notifications.service.ts`, `notifications.controller.ts`
  - `push-sender.ts`: the interface, the Noop and FCM senders, and the provider factory
  - `devices.controller.ts`, `admin-broadcast.controller.ts`
  - `dto/*`
  - `notification-texts.ts`: Arabic templates
- `src/alerts/`: `alerts.module.ts`, `stock-alerts.service.ts`, `expiry-warnings.service.ts`
- `src/jobs/`: `jobs.module.ts`, `nightly-jobs.service.ts`, `ledger-assert.service.ts`, `jobs-scheduler.ts`, `admin-jobs.controller.ts`
- Tests:
  - `test/unit/{quantity-format,fcm-push-sender,notification-texts}.spec.ts`
  - `test/integration/{notifications.service,stock-alerts,expiry-warnings,nightly-jobs,notifications-constraints}.spec.ts`
  - `test/e2e/{notifications,notification-events,broadcast,admin-jobs}.e2e-spec.ts`

**Backend — modify:**
- `prisma/schema.prisma`
- `src/config/env.schema.ts`, `vitest.config*.mts` (`JOBS_ENABLED=false`)
- `src/app.module.ts`
- `src/orders/*.service.ts`, `src/orders/orders.module.ts`
- `src/users/users.service.ts`, `src/users/users.module.ts`
- `src/estimation/auto-decrement.service.ts`
- `src/common/errors/error-codes.ts`

**`packages/api_client`:**
- `lib/src/models/notification.dart`
- `lib/src/notifications/{notifications_api,admin_notifications_api}.dart`
- tests

**`client`:**
- `lib/core/notifications_controller.dart`
- `lib/features/notifications/{notification_bell,notifications_screen}.dart`
- router, home app bar, ARB
- `test/notifications_test.dart`

**`admin`:**
- `lib/core/notifications_controller.dart`
- `lib/features/notifications/{notifications_screen,compose_broadcast_screen}.dart`
- shell tab, router, ARB
- `test/notifications_test.dart`

---

### Task 1: Schema, dependencies and configuration

**Produces:**
- Enums:
  - `NotificationType` (spec §6: `ACCOUNT_APPROVED ACCOUNT_REJECTED ORDER_PLACED ORDER_CONFIRMED ORDER_OUT_FOR_DELIVERY ORDER_DELIVERED ORDER_CANCELLED LOW_STOCK OUT_OF_STOCK CLIENT_OUT_OF_STOCK EXPIRY_WARNING ADMIN_BROADCAST`)
  - `JobRunStatus { RUNNING SUCCEEDED FAILED }`
- Models:
  - `Notification` (spec §6, with a FK to users, `@@index([recipientUserId, readAt, createdAt])`, and `@@index([dedupeKey, createdAt])`)
  - `DeviceToken` (spec §6: `fcmToken @unique`, a FK to users with cascade)
  - `JobRun { id, job String, status, startedAt, finishedAt?, summary Json?, error String? }`
- CHECK `job_runs_finished_matches_status`: `("status" = 'RUNNING') = ("finishedAt" IS NULL)`.
- Env: `JOBS_ENABLED` (a boolean, default true; `false` in both vitest configs) and `FIREBASE_SERVICE_ACCOUNT_JSON` (an optional string).
- `npm install @nestjs/schedule firebase-admin`.

- [ ] Tests (integration, `notifications-constraints.spec.ts`):
  - a RUNNING run with `finishedAt` is rejected by name;
  - a SUCCEEDED run without `finishedAt` is rejected;
  - valid rows are accepted;
  - a notification for a missing user is rejected by its FK.
- [ ] Watch them fail (the tables are missing). Migrate, append the CHECK, generate, and watch them pass.
- [ ] `env.schema` test: `JOBS_ENABLED='false'` parses to false, and the default is true.
- [ ] Commit `feat(backend): add notifications, device tokens and job runs to the schema`.

### Task 2: Notifications core, push, devices

**Produces:**
- `formatQuantityAr(units, unitsPerBox, unitLabelAr): string`. It matches the Dart `formatQuantity` with `boxLabel` «علبة»: 230/100 → `2 علبة + 30 سرنجة`.
- `interface PushMessage { title: string; body: string; data: Record<string, string> }`, and `interface PushSender { send(tokens: string[], message: PushMessage): Promise<{ invalidTokens: string[] }> }`.
- `PUSH_SENDER` injection token, provided by `pushSenderFactory(env)`.
- `NotificationsService`:
  - `create(db, input: NewNotification): Promise<Notification>`
  - `push(notifications: Notification[]): Promise<void>`: best-effort, and deletes invalid tokens.
  - `list(userId, { cursor?, limit? }): Promise<NotificationPage>`, newest first, including `unreadCount`.
  - `unreadCount(userId)`
  - `markRead(userId, id)`: another user's id → 404 `NOTIFICATION_NOT_FOUND`.
  - `markAllRead(userId): Promise<{ updated: number }>`
- Routes:
  - `GET /notifications`, `GET /notifications/unread-count`, `POST /notifications/:id/read`, `POST /notifications/read-all` (any signed-in role);
  - `POST /devices {fcmToken, platform: 'android'|'ios'|'web'}` (upsert: a token that moves to another user is re-owned);
  - `DELETE /devices/:fcmToken` (own only).
- View: `{ id, type, titleAr, bodyAr, payload, readAt, createdAt }`, and `NotificationPage { items, nextCursor, unreadCount }`.

- [ ] Unit tests:
  - `formatQuantityAr`:
    - 0 → `0 علبة`
    - 200/100 → `2 علبة`
    - 30/100 → `30 سرنجة`
    - 230/100 → `2 علبة + 30 سرنجة`
  - `FcmPushSender`, with a fake `messaging`:
    - It sends one multicast per 500 tokens.
    - `data` is passed through, and the title and body land in `notification`.
    - Tokens whose response errors with `messaging/registration-token-not-registered` or `messaging/invalid-registration-token` come back in `invalidTokens`; other errors do not.
    - An empty token list sends nothing.
- [ ] Integration (`notifications.service.spec.ts`):
  - **`push` sends to the recipient's devices only.**
  - **Dead tokens:** a sender reporting a token invalid → that `DeviceToken` is deleted.
  - **A sender that throws** → `push` resolves and the notification row is still there.
  - **No devices** → the sender is not called.
- [ ] E2E (`notifications.e2e-spec.ts`):
  - **Listing:** newest first, and paged by cursor. `unreadCount` counts unread rows only. Only the caller's own notifications are listed.
  - **Marking read:** `read` sets `readAt`, and marking again keeps the first `readAt`. Another user's id → 404. `read-all` returns the count and leaves other users untouched.
  - **Unread count:** `unread-count` matches.
  - **Devices:**
    - `POST /devices` upserts, and the same token from another user moves to that user.
    - `DELETE` removes only the caller's own token (another user's → 404).
    - A bad platform → 400.
  - **Auth:** no token → 401.
- [ ] Commit `feat(backend): add stored notifications, device tokens and best-effort push`.

### Task 3: Order and account notifications

**Produces:** calls to `notifications.create(tx, …)` inside:
- `OrdersService.place`;
- `OrderConfirmationService.confirm`;
- `OrderFulfilmentService.dispatch`/`deliver`;
- `OrderCancellationService.cancel`;
- `UsersService.approve`/`reject`.

Each is followed by `notifications.push(created)` after the commit. The texts live in `notification-texts.ts` (Arabic):
- `ORDER_CONFIRMED` «تم تأكيد طلبك» / «سيتم تجهيز طلبك وإرساله قريباً.» (with a shortfall: «تم تأكيد طلبك مع نقص في بعض الأصناف»);
- `ORDER_OUT_FOR_DELIVERY` «طلبك في الطريق إليك»;
- `ORDER_DELIVERED` «تم توصيل طلبك»;
- `ORDER_CANCELLED` «تم إلغاء طلبك»;
- `ORDER_PLACED` «طلب جديد من {clinic}»;
- `ORDER_CANCELLED` (to admins) «ألغى {clinic} طلبه»;
- `ACCOUNT_APPROVED` «تمت الموافقة على حسابك»;
- `ACCOUNT_REJECTED` «لم تتم الموافقة على حسابك».

Order notifications carry the payload `{orderId}`.

- [ ] Unit tests (`notification-texts.spec.ts`): each template renders its Arabic with the clinic name and order reference, and a shortfall confirmation uses the shortfall title.
- [ ] E2E tests (`notification-events.e2e-spec.ts`), one per transition:
  - **Placement:** placement notifies every active admin and not the clinic.
  - **Confirmation:**
    - A confirmation notifies the clinic with `{orderId}`.
    - A short confirmation uses the shortfall title.
    - A 409 double-confirm creates exactly one notification.
  - **Dispatch and delivery:** each notifies the clinic.
  - **Cancellation:**
    - An admin cancel notifies the clinic.
    - A clinic cancel notifies the admins and not the clinic.
  - **Accounts:** approve and reject notify the account.
  - **Push failure:** with a throwing push sender (override `PUSH_SENDER`), a confirmation still returns 200 and its notification exists.
- [ ] Commit `feat(backend): notify clinics and admins of order and account events`.

### Task 4: Stock alerts and expiry warnings

**Produces:**
- `StockAlertsService.run(now): Promise<{ created: number }>` (decision 2). It reads statuses through `InventoryReadService.entries(clientId, now)`, so the alert and the badge can never disagree (§7.6).
- `ExpiryWarningsService.run(now): Promise<{ created: number }>` (decision 3).

Texts:
- `LOW_STOCK` «{item}: الكمية قليلة» / «المتبقي {qty}. اطلب الآن حتى لا ينفد.»
- `OUT_OF_STOCK` «نفد {item}» / «اطلب الآن من التطبيق.»
- `CLIENT_OUT_OF_STOCK` «نفد {item} لدى {clinic}»
- `EXPIRY_WARNING`: clinic «دفعة {batch} من {item} تنتهي في {date}»; admin «دفعة {batch} من {item} في المستودع تنتهي في {date}»

Payload: `{itemId}` for the clinic.

- [ ] Integration tests (`stock-alerts.spec.ts`, fixed `now`):
  - **RED → LOW_STOCK once.** A RED item (qty > 0) → one `LOW_STOCK` with the item name and «المتبقي» text. A second run the same day → none. A run 8 days later, still red → a second one.
  - **Out of stock:**
    - The item goes to 0 inside the LOW_STOCK window → an `OUT_OF_STOCK` at once.
    - Every active admin gets `CLIENT_OUT_OF_STOCK`, and a suspended admin does not.
  - **No alert for:**
    - YELLOW, GREEN or UNKNOWN items;
    - a suspended clinic;
    - an inactive item at 0.
  - **Settings:** `alerts.repeatAfterDays = 2` is honoured.
- [ ] Integration (`expiry-warnings.spec.ts`):
  - **Warehouse batches:** a batch with stock expiring at `today + 60` → every active admin, once (a second run creates none). `today + 61` → none. A batch with 0 remaining → none.
  - **Held batches:** a held batch expiring at `today + 10` → the holding clinic, once, with `{itemId}`. One that expired yesterday → none.
- [ ] Commit `feat(backend): raise deduplicated stock alerts and expiry warnings`.

### Task 5: The nightly runner, ledger assert, scheduling, admin endpoints

**Produces:**
- `LedgerAssertService.run(): Promise<{ warehouseDrift: number; shelfDrift: number; samples: unknown[] }>` (decision 7).
- `NightlyJobsService.runAll(now): Promise<JobRunView[]>`. Jobs run in order:
  - `auto-decrement`
  - `recompute-estimates`
  - `evaluate-alerts`
  - `expiry-warnings`
  - `rebuild-hot-deals`
  - `ledger-assert`
  - each as a `JobRun`, pushing the notifications the alert jobs created.
  - Advisory lock (decision 5).
- `JobsScheduler`: at bootstrap, if `JOBS_ENABLED`, it registers a `CronJob('0 30 0 * * *', …, timeZone)` in the `SchedulerRegistry`.
- `AutoDecrementResult` gains `failed`.
- Routes (admin only): `POST /admin/jobs/nightly` (runs now and returns the runs; 409 `JOBS_ALREADY_RUNNING`) and `GET /admin/jobs/runs?limit` (newest first).

- [ ] Integration (`nightly-jobs.spec.ts`):
  - **Order:** `runAll` creates six `JobRun` rows in §8 order, all SUCCEEDED, each with a summary.
  - **Failure isolation:**
    - With `rebuild-hot-deals` forced to throw (spy), its run is FAILED with the error, and `ledger-assert` still runs and succeeds.
    - With `decrementOne` spied to throw for one row, the other row is still decremented, and `failed: 1`.
  - **Idempotency:** a second `runAll` the same night writes no new movements and no new notifications.
  - **Drift:** `ledger-assert` reports drift when a clinic cache is tampered (+5), and reports 0 on a clean database.
  - **Overlap:** while the advisory lock is held by another connection, `runAll` throws `JOBS_ALREADY_RUNNING`.
- [ ] E2E (`admin-jobs.e2e-spec.ts`): the admin POST returns six runs, and GET lists them. A client token → 403.
- [ ] Commit `feat(backend): run the six nightly jobs in order, logged, isolated and non-overlapping`.

### Task 6: Admin broadcast

**Produces:** `POST /admin/notifications/broadcast { titleAr, bodyAr, audience: 'ALL' | 'SELECTED', clientIds?: string[] }` → `{ recipients: number }` (decision 8). It creates `ADMIN_BROADCAST` rows (payload null), then pushes.

- [ ] E2E (`broadcast.e2e-spec.ts`):
  - `ALL` reaches every ACTIVE clinic and no one else (not suspended or pending clinics, and not admins).
  - `SELECTED` reaches exactly those.
  - Unknown ids, or a suspended clinic's id → 400 listing them.
  - `SELECTED` with no ids → 400. An empty title, a body over 1000 characters → 400.
  - A client token → 403.
- [ ] Commit `feat(backend): let the admin message all clinics or chosen ones`.

### Task 7: `api_client` — notifications

**Produces:**
- `enum NotificationType` (with an unknown fallback).
- `AppNotification { id, type, titleAr, bodyAr, orderId?, itemId?, readAt?, createdAt, bool get isRead }`.
- `NotificationPage { items, nextCursor, unreadCount }`.
- `NotificationsApi { list({cursor, limit}), unreadCount(), markRead(id), markAllRead(), registerDevice(token, platform), unregisterDevice(token) }`.
- `AdminNotificationsApi { broadcast({titleAr, bodyAr, List<String>? clientIds}) → int }` (null ids = ALL).
- `JobRun` model and `AdminJobsApi { runNightly(), runs() }`.

- [ ] Tests: the models parse (with and without a payload, and an unknown type); each API method's path, method, body and query. Then a real-JSON wire check, temporary and not committed.
- [ ] Commit `feat(api_client): add notifications, broadcast and job-run APIs`.

### Task 8: Client — the bell and the notification centre

**Produces:**
- `unreadCountProvider` (`autoDispose`, no retry, hidden on failure).
- `notificationsProvider` (paged `AsyncNotifier`).
- A bell `IconButton` in the home app bar, with a `Badge` showing the count (hidden at 0), tooltip «الإشعارات».
- Route `/notifications`.

The screen:
- Newest first. Unread cards have a bold title and a dot.
- Tapping a card marks it read, then goes to `Routes.order(orderId)` or `Routes.inventoryItem(itemId)`, or stays put.
- «تحديد الكل كمقروء» sits at the top, and «عرض المزيد» pages.
- The empty state reads «لا توجد إشعارات».

- [ ] Widget tests:
  - **Bell badge:** the badge shows the unread count and is hidden at 0.
  - **Opening:** the bell opens the centre, which lists the titles and bodies newest first.
  - **Tapping:**
    - An order notification marks it read (POST) and lands on the order screen.
    - An item notification lands on the item's history.
  - **Mark all read:** posts, and the dots disappear.
  - **Empty state:** shown when there are no notifications.
  - **Layout:** fits 390 px at 1.5× text.
- [ ] Commit `feat(client): add the notification bell and centre`.

### Task 9: Admin — inbox and broadcast

**Produces:**
- A «الإشعارات» tab in the shell, showing the admin's inbox (as the client's, with deep links to the order).
- A «رسالة جديدة» button that opens the compose screen:
  - title and body fields;
  - audience: «جميع العملاء» or «عملاء محددون»;
  - a checkbox list of ACTIVE clinics (from `/admin/users?status=ACTIVE`);
  - «إرسال».
- On success, a snackbar «تم الإرسال إلى {n} عميل».

- [ ] Widget tests:
  - **Inbox:** the tab lists the admin's notifications, and an order notification opens the order.
  - **Sending:**
    - Sending to all posts `{titleAr, bodyAr, audience: 'ALL'}`.
    - Choosing two clinics posts `audience: 'SELECTED'` with their ids.
  - **Validation:** an empty title or body shows a message and sends nothing.
  - **Refusal:** a server refusal shows its message.
  - **Layout:** fits 390 px.
- [ ] Commit `feat(admin): add the notifications inbox and broadcast composer`.

### Task 10: Documentation and gates

- [ ] Run every gate (as Phase 4 Task 14).
- [ ] Update RESUME:
  - Phase 5 ✅, and the counts.
  - The decisions worth not relitigating.
  - **The FCM hand-off for the user.** Create a Firebase project; set `FIREBASE_SERVICE_ACCOUNT_JSON` on the server; run `flutterfire configure` in `client`. Then the client registers its token with `POST /devices`, and a later task wires `firebase_messaging`.
- [ ] Commit `docs: Phase 5 complete in RESUME`.

## Deferred, with their owning phase

- Client FCM registration (`firebase_messaging`, platform config) is **blocked on the user's Firebase project**.
- The admin dashboard, out-of-stock popups and the run-log view are **Phase 6**.
- Auditing broadcasts is not in §7.9's list, so it is not done.
