# Phase 7: Everything Works (Functional Hardening) Implementation Plan

> **For agentic workers:** executed inline (superpowers:executing-plans), TDD per task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** every existing flow works on a real phone and a real browser, before any visual work.

**Why this phase was re-scoped:** the spec's Phase 7 was "hardening": RTL, theme and responsive audits, performance, the E2E loop, seed data, deployment and backups. After testing by hand, the user set this order (2026-09-30):
1. everything functional;
2. Firebase push;
3. temporary free hosting;
4. item pictures;
5. UI and looks last.

This plan is step 1. Steps 2–5 become Phases 8–11 (see the end), each planned when it is reached. The visual audits (RTL, theme, responsive, Arabic-Indic digits) move to Phase 11.

**Architecture:** no new backend features. The fixes are in the two Flutter apps' navigation, session handling and data freshness. Every fix starts with a test that reproduces it in a widget test.

**Tech stack:** Flutter 3.32, Riverpod 3, go_router, `api_client` fakes (`FakeApiBackend`).

**Spec:** `docs/superpowers/specs/2026-09-27-medical-inventory-design.md`

## Already fixed before this plan (commit fbfd411, 2026-09-30)

These came from the user's own testing:
- **Admin red screen after every save:** four dialogs disposed their text controllers while the dialog was still closing.
- **Admin tabs:** they zoomed like a new app opening; tabs now switch instantly.
- **Client search:** the first letter jumped to a screen with no search box. Search is now in place on home.
- **Client pages:** they now fade (200 ms) instead of zooming.
- **Earlier the same day:**
  - log out was moved into a menu, with a confirmation;
  - "can't reach the server" no longer logs the clinic out;
  - «إبقني مسجّلاً الدخول» was added.

## Global constraints

- **Audience:** clinic staff aged 30+, many older.
  - Big targets, no surprises.
  - The phone's back button must behave as they expect.
  - Fix what real users will meet; skip near-impossible races.
- **Arabic only, RTL.** New strings go through the ARB files.
- **No colour literals** outside `ui_kit` palette (`check_colors`).
- **Formatting:** don't run the formatter over whole directories. Edit files by hand.
- **Gates at the end:**
  - all suites green;
  - `flutter analyze` clean in both apps;
  - `check_colors` OK;
  - the admin web build succeeds;
  - `npm run typecheck`, if the backend is touched.

## Review focus

1. **Client back button:** the phone's back button on any client screen must go to that screen's parent, never close the app. Home is the only exit.
2. **Client, session ended by the server:** a clinic whose session the server ended must land on the login screen with a clear message, not a screen of errors. The server ends sessions when an admin suspends the account or resets its password.
3. **Admin, server down at page load:** an admin page loaded while the server is down must keep the session and offer a retry. The client already does this.
4. **Fresh data per visit:** anything someone else can change must show its current value when a screen is opened again:
   - for clinics: prices, stock, deals, cart;
   - for the admin: registrations, batch quantities, item stock, deals.
5. **Search still works:** the in-place search keeps working when the user leaves for an item and comes back.

---

### Task 1: The phone's back button goes back (client)

Every client page is shown with `context.go`, so the page stack is always one page. The phone's back button therefore closed the app from the cart, an order, an item, anywhere.

**Fix:** a shared `BackTo(route)` wrapper. It is a `PopScope` that cancels the pop and `go`es to the page's parent. Each non-home page is wrapped with the same parent its app-bar arrow already uses. Home keeps `PopScope(canPop: !searching)`, so back leaves search first, then the app.

**Files:**
- Create: `client/lib/core/back_to.dart`
- Modify: every client screen with a `BackButtonIcon` leading:
  - cart
  - orders
  - order detail
  - category
  - item detail
  - inventory
  - inventory item
  - stock count
  - notifications
- Modify: the register and pending-approval screens (parent: login).
- Test: `client/test/navigation_test.dart`, using `tester.binding.handlePopRoute()`:
  - back on the cart → home;
  - back on orders → home;
  - back on an order → orders;
  - back on inventory → home;
  - back on an inventory item → inventory;
  - back on notifications → home;
  - back on an item → its category, or home;
  - back on register → login.

**Steps:**
- [ ] Write `navigation_test.dart` and watch it fail: `handlePopRoute` returns false, so the app would close.
- [ ] Add `BackTo` and wrap each screen.
- [ ] The suite goes green. Commit.

### Task 2: A session the server ended goes back to the login screen (client)

`AuthInterceptor` clears the stored tokens when a refresh is refused, but `AuthState` stayed `AuthAuthenticated`. Every request then failed with «يجب تسجيل الدخول أولاً» and there was no way out but the menu. The server ends sessions on suspend and on an admin password reset (`revokeAllForUser`).

**Fix:**
- `SessionTokenStore` gets an `onCleared` callback.
- `AuthController` sets it: a clear while `AuthAuthenticated` becomes `AuthLoggedOut(sessionEnded: true)`.
- The login screen then shows «انتهت الجلسة، يرجى تسجيل الدخول مرة أخرى».
- A normal log out keeps the plain login screen.

**Files:**
- Modify: `client/lib/core/session_token_store.dart`
- Modify: `client/lib/core/auth_controller.dart`
- Modify: `client/lib/features/auth/login_screen.dart`
- Modify: the ARB file.
- Test: `client/test/auth_flow_test.dart`
  - "a session the server ended returns to login, saying so": signed in; `/categories` returns 401 TOKEN_EXPIRED; `/auth/refresh` returns 401 TOKEN_INVALID; the pull-to-refresh request fails; the login screen shows the message; the store is empty.
  - "logging out does not say the session ended".

**Steps:** test first (RED), then the fix (GREEN), then the suite, then commit.

### Task 3: The admin keeps its session when the server is down at page load

The admin `restore()` cleared the session on any error, like the client used to.

**Fix:** the same as the client.
- Only a 401 or 403 clears the session.
- Anything else becomes `AuthUnreachable`, and a splash shows «تعذر الاتصال بالخادم» with «إعادة المحاولة».

**Files:**
- Modify: `admin/lib/core/auth_controller.dart`
- Modify: `admin/lib/core/router.dart`
- Create: `admin/lib/features/auth/splash_screen.dart`
- Modify: the admin ARB file.
- Test: `admin/test/accounts_test.dart` (the auth group)
  - "a server it cannot reach keeps the session, and retry signs in";
  - the existing "a stored but rejected token falls back to login" still passes.

### Task 4: Fresh data on every visit (both apps)

Providers that were never disposed kept their first answer for the whole session. For example:
- the accounts tab didn't show a clinic that registered after the tab was first opened, while the dashboard counted it;
- a clinic saw an old price on an item it had opened before.

**Fix:** make them `autoDispose`. Each page is shown alone (`go`), so leaving a page drops its data and the next visit fetches it again. The in-app actions' `ref.invalidate` calls keep working.

- **Client:**
  - `categoryTreeProvider`
  - `categoryItemsProvider`
  - `itemDetailProvider`
  - `hotDealsProvider`
  - `cartProvider`
  - `searchResultsProvider` (`searchQueryProvider` stays kept alive, so search survives a visit to an item)
- **Admin:**
  - `accountsProvider` and its derived `accountProvider`
  - `categoryTreeProvider`
  - `itemsProvider`
  - `batchesProvider`
  - `itemStockProvider`
  - `adminHotDealsProvider`

**Tests:**
- Admin: "a clinic that registers while the admin is elsewhere appears when the accounts tab is opened".
- Admin: "batch quantities are current each time the batches tab opens".
- Client: "an item's new price shows the next time the item is opened".
- Client: "search results come back after visiting an item".

Each test changes the fake backend's answer between two visits.

**Steps:** tests first (RED), then the providers (GREEN). Fix any test that relied on a stale cache, with a ruling in the ledger. Then the suites, then commit.

### Task 5: Close-out

- [ ] Full gates (see Global constraints).
- [ ] `docs/RESUME.md`: Phase 7 done, the new roadmap (Phases 8–11), and the test counts.
- [ ] `docs/SETUP-AND-TESTING.md`: re-test steps for the back button, the session message, the admin retry, and fresh lists.
- [ ] A self-review of the whole diff against the review focus above, since no subagent reviewer is used (the user's budget). Commit and push.

---

## After Phase 7: the user's roadmap

Each phase gets its own plan when it is reached.

- **Phase 8: Firebase push.**
  - Needs the user to create a Firebase project and choose the app id (`com.example.client` is a placeholder).
  - Then `flutterfire configure`, `firebase_messaging` in the client, token registration through the existing `POST /devices`, and `FIREBASE_SERVICE_ACCOUNT_JSON` on the server.
- **Phase 9: Temporary free hosting.**
  - Backend Docker image.
  - Free web host plus free Postgres, for example Render with Neon.
  - Keep Postgres on UTC.
  - A demo-data seed so a fresh database is testable.
  - The client built with the hosted `API_BASE_URL`; the admin web hosted as static files.
- **Phase 10: Item pictures.**
  - Upload per spec §10.6: 5 MB max, jpg/png/webp, magic-byte check, a `sharp` thumbnail and a full-size variant.
  - An admin upload UI; the client shows the pictures.
  - Storage must suit the chosen host (its disk may be temporary).
- **Phase 11: UI and looks.**
  - The user's UI comments.
  - The RTL, theme and responsive audits.
  - A large-text check at 390 px.
  - Arabic-Indic digits.
