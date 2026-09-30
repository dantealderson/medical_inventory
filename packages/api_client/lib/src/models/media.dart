/// Pictures. Items and categories store the full size's URL, relative to the
/// server (`/api/v1/media/<id>.webp`), so a new host does not break them. The
/// thumbnail sits next to it (`<id>.thumb.webp`).
library;

/// The thumbnail of a stored picture. Anything else is returned as it is.
String thumbnailOf(String imageUrl) {
  if (!imageUrl.endsWith('.webp') || imageUrl.endsWith('.thumb.webp')) return imageUrl;
  return '${imageUrl.substring(0, imageUrl.length - '.webp'.length)}.thumb.webp';
}

/// Where to load a stored picture from. It resolves against the server's
/// origin: the stored URL already starts with `/api/v1`.
Uri mediaUri(String baseUrl, String imageUrl, {bool thumbnail = false}) =>
    Uri.parse(baseUrl).resolve(thumbnail ? thumbnailOf(imageUrl) : imageUrl);
