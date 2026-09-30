# Phase 10: Item and Category Pictures Implementation Plan

> **For agentic workers:** executed inline (superpowers:executing-plans), TDD per task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** the admin can give every item and category a picture, and clinics see the pictures in the app.

**Order:** by the user's choice (2026-10-01), this runs before Phase 9 (hosting prep) and a first UI pass. Phase 8 (Firebase) waits for the user.

**Spec:** `docs/superpowers/specs/2026-09-27-medical-inventory-design.md` §10.6:
- max 5 MB;
- jpg, png or webp, checked by decoding the bytes, never by the file name;
- `sharp` makes a thumbnail and a full-size variant;
- relative URLs are stored, so the host can change.

## What exists (Phase 2)

- **`POST /admin/media`:** decodes with `sharp`, then writes `<uuid>.webp` and `<uuid>.thumb.webp` to `UPLOAD_DIR`, served at `/uploads/`. It returns `{url, thumbnailUrl}`.
- **Items and categories** take an `imageUrl` string on create and update.
- **The client's hot-deals card** resolves `imageUrl` against the API origin.
- **Nothing in either app uploads a picture.** The full variant is not resized, and EXIF rotation is ignored, so a phone photo stays sideways and several MB.

## Decisions

1. **Pictures are stored in Postgres (`media_files`), not on disk.**
   - **Why:** Phase 9's free hosts wipe the disk on every restart, so files would vanish. A table survives any host, needs no extra account, and is in every database backup.
   - **Cost if wrong:** the database grows by about 150 KB per picture, around 75 MB for 500 items. That fits a free Postgres (0.5 GB). A later move to disk or S3 stays inside `MediaService`.
   - **The spec's "VPS filesystem" line is superseded by this.**
2. **Upload and attach happen in one request:**
   - `PUT /admin/items/:id/image` and `PUT /admin/categories/:id/image` take the file (multipart field `file`).
   - They store it, point the row at it, delete the previous picture, and audit the change.
   - `DELETE .../image` removes it.
   - No orphan pictures come from cancelled dialogs. `POST /admin/media` and the disk code are removed.
3. **URLs:**
   - Full size is `/api/v1/media/<uuid>.webp`; the thumbnail is the same with `.thumb.webp`.
   - `GET /media/:file` is public. Catalogue photos are not sensitive, the uuid is unguessable, and `Image.network` sends no token.
   - Responses carry `Cache-Control: public, max-age=31536000, immutable`, because a new upload always gets a new uuid.
4. **Processing:**
   - `rotate()` applies the EXIF orientation.
   - The full variant fits inside 1200×1200 and the thumbnail inside 300×300, never enlarged. Both are webp. Metadata is stripped, as `sharp` does by default.

## Tasks

### Task 1: Pictures in the database, served publicly (backend)

- **Migration `media_in_database`:**
  - `MediaFile { id uuid, full Bytes, thumb Bytes, createdAt }`, mapped to `media_files`.
- **`MediaService`:**
  - `store(buffer) → {url, thumbnailUrl}`;
  - `read(file) → Buffer | null`;
  - `removeByUrl(url)`, which ignores URLs that are not ours.
- **`MediaController`:** `GET media/:file`, `@Public`, with image/webp and the immutable cache header. A missing file returns a 404 with the usual envelope.
- **Removed:**
  - the disk writes and the `/uploads` static serving;
  - `UPLOAD_DIR`;
  - `POST /admin/media`.
- **Tests (`test/e2e/media.e2e-spec.ts`, rewritten):**
  - the served full size and thumbnail decode as webp, with sizes ≤ 1200 and ≤ 300;
  - a 20×10 JPEG with EXIF orientation 6 comes back 10×20;
  - an unknown file returns 404;
  - the service rejects non-image bytes (INVALID_IMAGE) and over 5 MB (IMAGE_TOO_LARGE);
  - reading needs no token.

### Task 2: Attach, replace and remove pictures (backend)

- **Endpoints:** `PUT` and `DELETE` for `/admin/items/:id/image` and `/admin/categories/:id/image`. Each returns the updated item or category view.
- **Behaviour:**
  - replacing a picture deletes the old one;
  - audited as `ITEM_UPDATED` or `CATEGORY_UPDATED`, with `before.imageUrl` and `after.imageUrl`.
- **Tests:**
  - set, replace (the old URL returns 404), and remove, for an item and a category;
  - a CLIENT is refused;
  - an unknown id returns 404;
  - a non-image is refused and the item is unchanged.

### Task 3: `api_client`

- **Methods:**
  - `ItemsApi.setImage(id, bytes, filename)` and `removeImage(id)`;
  - `CategoriesApi.setImage` and `removeImage` (on whichever classes hold the admin calls).
- **Helpers:**
  - `thumbnailOf(imageUrl)`: `.webp` becomes `.thumb.webp`;
  - `mediaUri(baseUrl, imageUrl)`: resolves against the origin.
- **Tests:** multipart is sent to the right path, and both helpers.

### Task 4: Admin upload (items and categories)

- **Each item and category row:**
  - a thumbnail, with a placeholder when there is none;
  - «الصورة» actions: «اختيار صورة» and «حذف الصورة», the second after a question.
- **Picking:** through an injectable `imagePickerProvider`, so tests use a fake. The real one uses `file_picker` (web).
- **After an action:** the list is invalidated, and a snackbar shows «تم حفظ الصورة» or the server's Arabic error.
- **Tests:**
  - choose → PUT sent → thumbnail shown;
  - the server refusal is shown;
  - removing asks first.

### Task 5: Pictures in the client

- **An `ItemPicture` widget:**
  - resolves against `apiBaseUrl`;
  - uses the thumbnail unless full size is asked for;
  - shows the existing placeholder icon when there is no picture or it fails to load.
- **Used on:**
  - item cards (thumbnail);
  - item detail (full size, at the top);
  - category tiles (only when a category has a picture);
  - hot deals (thumbnail);
  - cart lines (thumbnail).
- **Tests:** the right URL per place; the placeholder for none.

### Task 6: Close-out

- Gates:
  - backend typecheck, unit and e2e tests;
  - api_client and both app suites;
  - analyze;
  - `check_colors`;
  - the admin web build.
- Update RESUME and the testing guide (a new test step).
- Self-review, commit and push.
