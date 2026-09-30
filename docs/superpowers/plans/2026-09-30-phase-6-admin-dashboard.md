# Phase 6 — Admin Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The admin opens the app to one screen that says what needs attention now:
- accounts waiting for approval;
- orders waiting for confirmation;
- clinics that have run out of something, as a prominent alert;
- warehouse items that are low or out;
- batches expiring within 60 days, plus expired ones still in stock;
- whether last night's jobs ran.

The rest of §12.1 lands here too:
- the audit log (read-only, filtered);
- settings (validated, audited);
- a clinic's orders on its account page.

**Explicitly absent: revenue, profit, sales charts, any cashflow (requirement 10).**

**Architecture:** Backend `src/dashboard/` (one read endpoint), `src/settings/admin-settings.controller.ts` (validated PATCH), and `src/audit/admin-audit.controller.ts` (filtered, paged read). Admin app: a dashboard as the home tab, plus settings and audit tabs.

**Spec:** §7.9 (audit: settings changes are logged; the log is filterable by actor, entity and date), §9 (settings), §12.1 (screens), §15 (Phase 6). Requirement **10**.

**Execution:** as Phases 4–5. The plan carries decisions, interfaces and exact test cases; code is written once, test-first; deviations are ledgered.

## Global Constraints

- **Everything from Phases 0–5 still applies.** The admin works at 390 px.
- **The dashboard is read-only and cheap.** It is a handful of aggregate queries, with no per-row N+1.
- **No money anywhere on the dashboard,** and no charts.
- **Settings are the only way to retune thresholds** (§9). Every change is validated and audited (`SETTINGS_CHANGED`).

## Review Focus

1. **A clinic that ran out, then stopped tracking the item,** is not shown as out of stock. An inactive item is not either.
2. **A setting that would break the system is refused:**
   - yellow ≤ red;
   - negative shelf life (the Phase 3 deferred guard);
   - a minimum purchase window longer than the window itself;
   - a changed time zone.
3. **The out-of-stock popup appears once per session.** It does not reappear every time the admin returns to the dashboard.
4. **A warehouse item with no batches at all** shows as out. Expired stock does not count as stock.
5. **Audit log filters:** by entity type, by actor and by date range, including a whole calendar day.

## Decisions (do not relitigate)

| # | Decision | Why |
|---|---|---|
| 1 | "Out of stock clinic" means an ACTIVE clinic with a tracked (`trackingStoppedAt` null) inventory row of an active item at qty 0. | The stop-tracking promise; the + is disabled for inactive items. |
| 2 | Warehouse usable stock = Σ `qtyUnitsRemaining` of batches with `expiryDate ≥ today` (Baghdad). **Out** when 0, including items never stocked. **Low** when below `item.minQtyUnits` (the only per-item threshold that exists). Active items only. | Expired stock cannot ship (§8), so it is not stock. |
| 3 | Expiring = stock > 0 and expiry in `[today, today + expiry.warnDaysAhead]`. Expired batches with stock are listed too, flagged `expired`, because they need a write-off. | §8: never written off automatically, so the admin must see them. |
| 4 | The last nightly run is the latest `auto-decrement` JobRun and every run after it: `{ startedAt, finishedAt, failedJobs }`, or `null` if it never ran. The dashboard has «تشغيل الآن». | The run log deferred from Phase 5. |
| 5 | Settings are validated per key with a range, plus two cross-field rules: yellow > red, and `minPurchaseDays` ≤ `purchaseWindowDays`. `business.timezone` is read-only (the scheduler reads it at boot). Changes are written in one transaction with one `SETTINGS_CHANGED` audit entry (`before`/`after` of the changed keys only); nothing changed → no entry. | The Phase 3 guard; §7.9. |
| 6 | Audit read: filters `actorUserId`, `entityType`, `from`/`to` as `YYYY-MM-DD` Baghdad dates (inclusive), newest first, cursor paging, with the actor's username joined. | §7.9. |
| 7 | The admin order list gains a `clientId` filter; the account page lists that clinic's latest orders. | §12.1 client detail. |
| 8 | The dashboard is the home tab (`/`). Accounts move to `/accounts`. The popup shows once per app session (a keep-alive flag). | The admin lands on what needs attention. |

## Tasks

### Task 1: Dashboard endpoint

`GET /admin/dashboard` (admin only) →

```ts
{
  pendingAccounts: number,
  ordersAwaitingConfirmation: number,
  outOfStockClinics: [{ clientId, clinicName, username, items: [{ itemId, nameAr }] }], // by clinic name
  warehouse: [{ itemId, nameAr, unitsPerBox, unitLabelAr, usableUnits, minQtyUnits, level: 'OUT' | 'LOW' }], // OUT first, then by name
  expiringBatches: [{ batchId, batchNumber, itemId, nameAr, expiryDate, qtyUnitsRemaining, unitsPerBox, unitLabelAr, expired }], // by expiry
  lastNightlyRun: { startedAt, finishedAt, failedJobs: string[] } | null
}
```

- [ ] E2E tests (`dashboard.e2e-spec.ts`):
  - **Counts:** it counts PENDING clinics and PLACED orders only.
  - **Out-of-stock clinics:**
    - One clinic at 0 on two items is one entry with two items.
    - A stopped item, an inactive item, a suspended clinic, or a qty > 0 → not listed.
  - **Warehouse:**
    - An item never stocked → OUT.
    - An item whose only batch expired → OUT.
    - Stock below the item minimum → LOW.
    - Stock at the minimum → not listed.
    - An inactive item → not listed.
  - **Expiring batches:** `today + 60` is listed, `today + 61` is not, one that expired yesterday with stock is listed as `expired: true`, and a batch at 0 is not listed.
  - **Last nightly run:** `null` before any run. After `runAll` it has six jobs and `failedJobs: []`.
  - **Access:** a client token → 403.
- [ ] Commit `feat(backend): add the admin dashboard`.

### Task 2: Settings

- `GET /admin/settings` → `{ values: Record<key, value>, readOnly: ['business.timezone'] }`.
- `PATCH /admin/settings { values: { [key]: number } }` → the same shape.

The ranges:

| Setting | Range |
|---|---|
| `stock.redDaysOfCover` | 1..365 |
| `stock.yellowDaysOfCover` | 2..365, and > red |
| `estimation.purchaseWindowDays` | 7..730 |
| `estimation.minPurchaseDays` | 1..730, and ≤ window |
| `estimation.minMeasureDays` | 1..365 |
| `estimation.measurePairWindowDays` | 7..1095 |
| `estimation.maxCatchUpDays` | 1..365 |
| `alerts.repeatAfterDays` | 1..90 |
| `expiry.warnDaysAhead` | 1..365 |
| `expiry.minShelfLifeOnDeliveryDays` | 0..365 |
| `hotDeals.rotationSeconds` | 2..60 |
| `hotDeals.frequentWindowDays` | 1..365 |
| `hotDeals.newItemDays` | 1..365 |
| `hotDeals.maxEntries` | 1..50 |

Rules:
- Integers only.
- An unknown key or `business.timezone` → 400.
- A violation → 400 `VALIDATION_FAILED` with `details: { key, reason }`, and nothing is written.

- [ ] E2E tests (`admin-settings.e2e-spec.ts`):
  - **Read:** GET returns the defaults.
  - **Change:**
    - PATCH red 5 → saved.
    - One `SETTINGS_CHANGED` audit entry with `before {stock.redDaysOfCover: 7}` and `after {…: 5}`.
    - Patching the same value again → no new audit entry.
  - **Refused (400), with nothing saved:**
    - yellow ≤ red, both in one patch and against the stored red;
    - `minShelfLife` −1;
    - `minPurchaseDays` > window;
    - a non-integer;
    - an unknown key;
    - the timezone.
  - **Access:** a client → 403.
- [ ] Commit `feat(backend): let the admin change settings, validated and audited`.

### Task 3: Audit log read, and orders by clinic

- `GET /admin/audit?entityType&actorUserId&from&to&cursor&limit` → `{ items: [{ id, action, entityType, entityId, actor: { id, username }, before, after, note, createdAt }], nextCursor }`.
- `GET /admin/orders?clientId=` filters by clinic.

- [ ] E2E tests (`admin-audit.e2e-spec.ts`):
  - **Order and paging:** newest first, paged.
  - **Filters:**
    - `entityType` filters, and so does `actorUserId`.
    - `from`/`to` are inclusive whole Baghdad days: an entry at 23:30 Baghdad on the `to` day is included, and 00:30 the next day is not.
    - A bad date → 400.
  - **Actor:** the username is included.
  - **Access:** a client → 403.
  - **Orders by clinic:** `clientId` returns only that clinic's orders.
- [ ] Commit `feat(backend): read the audit log with filters, and list a clinic's orders`.

### Task 4: `api_client`

**Produces:**
- `AdminDashboard` and its parts, with `AdminDashboardApi.get()`.
- `AdminSettings { values: Map<String, Object?>, readOnly }` and `AdminSettingsApi { get(), update(Map<String, int>) }`.
- `AuditEntry` and `AuditPage`, with `AdminAuditApi.list({entityType, actorUserId, from, to, cursor, limit})`.
- `AdminOrdersApi.list(clientId:)`.

- [ ] Tests: the models parse, and each request's path, query and body are checked. Plus a temporary wire check.
- [ ] Commit `feat(api_client): add dashboard, settings and audit APIs`.

### Task 5: Admin — dashboard as home

- Route `/` is the dashboard, and accounts move to `/accounts`. The first tab is «الرئيسية».
- **Cards:**
  - «حسابات بانتظار الموافقة» (count) → accounts;
  - «طلبات بانتظار التأكيد» (count) → orders;
  - a red card «عملاء نفد مخزونهم»: each clinic with its items, tapping opens that clinic's inventory;
  - «المستودع: أصناف ناقصة أو نافدة»: item, usable quantity in boxes and units, and «نفد» or «ناقص»;
  - «دفعات قاربت على الانتهاء»: batch, item, expiry, quantity, with «منتهية» for expired ones;
  - «التحديث الليلي»: last run time, OK or the failed jobs, and «تشغيل الآن».
- **The popup:** on the first dashboard load of the session with out-of-stock clinics, a dialog «عملاء نفد مخزونهم» lists them (clinic: items), with «عرض» and «إغلاق». It does not show again this session.

- [ ] Widget tests:
  - **Counts:** the dashboard shows the counts, and tapping them navigates.
  - **Out-of-stock clinics:**
    - The alert list shows each clinic with its items, and a tap opens that clinic's inventory.
    - The popup shows on the first visit and not after returning.
    - No out-of-stock clinics → no popup and no red card.
  - **Warehouse and expiring lists:** they show words, not only colours.
  - **Nightly run:** «تشغيل الآن» posts, then shows the new status.
  - **Layout:** it fits 390 px.
  - **Existing tests:** the login-landing test and the tests that use `/` are updated for the new home.
- [ ] Commit `feat(admin): add the dashboard as the home screen`.

### Task 6: Admin — settings and audit log

- **A «الإعدادات» tab:**
  - Grouped sections (stock, estimation, alerts, expiry, hot deals), each field with an Arabic label and a one-line explanation.
  - The timezone is shown read-only.
  - «حفظ» sends only the changed keys.
  - The server's refusal is shown next to the field it names.
- **A «سجل التدقيق» tab:**
  - A filter row: entity type (a dropdown of the known types), from and to dates.
  - A list: the action's Arabic label (unknown ones show the raw action), actor username, time, and a short before → after.
  - «عرض المزيد» for the next page.
- **The account page** lists the clinic's latest orders, each opening the order.

- [ ] Widget tests:
  - **Settings:**
    - They load with values, and editing red and saving sends only `{stock.redDaysOfCover: 5}`.
    - A 400 with `details.key` shows the message by that field.
    - The timezone is not editable.
  - **Audit log:** it lists the entries, and choosing an entity type and dates sends those filters.
  - **Account page:** it lists orders.
  - **Layout:** all fit 390 px.
- [ ] Commit `feat(admin): add settings, the audit log, and a clinic's orders`.

### Task 7: Docs and gates

- [ ] Run all gates.
- [ ] Update RESUME and `docs/SETUP-AND-TESTING.md` (the dashboard replaces the Swagger step for running the jobs).
- [ ] Commit.
