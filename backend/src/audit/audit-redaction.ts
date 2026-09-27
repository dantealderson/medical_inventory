export const REDACTED = '[REDACTED]';
const CIRCULAR = '[CIRCULAR]';

/**
 * Key fragments that mark a value as credential material. Matched
 * case-insensitively as substrings, so `passwordHash`, `PasswordHash` and
 * `oldPasswordHash` all hit.
 */
const SENSITIVE = ['password', 'token', 'secret', 'authorization', 'cookie'];

function isSensitiveKey(key: string): boolean {
  const k = key.toLowerCase();
  return SENSITIVE.some((s) => k.includes(s));
}

/**
 * Deep-copy with credential material replaced.
 *
 * Key-based by design: it cannot detect a secret embedded in free text, so
 * callers must not put credentials in `note`. There is a test asserting this
 * limitation so nobody assumes otherwise.
 *
 * An audit log that accumulates credential material is not a security
 * control; it is a breach waiting to be indexed.
 */
export function redact(value: unknown, seen: WeakSet<object> = new WeakSet()): unknown {
  if (value === null || typeof value !== 'object') return value;

  // Dates, Buffers and the like are opaque values, not containers. Recursing
  // into a Date yields {} — which would silently destroy every audit
  // timestamp while every test that only checked strings still passed.
  if (value instanceof Date || value instanceof RegExp || Buffer.isBuffer(value)) {
    return value;
  }

  if (seen.has(value)) return CIRCULAR;
  seen.add(value);

  if (Array.isArray(value)) return value.map((v) => redact(v, seen));

  const out: Record<string, unknown> = {};
  for (const [key, val] of Object.entries(value as Record<string, unknown>)) {
    // A sensitive key is redacted wholesale, whatever its value. Recursing
    // into `token: { ... }` would preserve the secret one level down.
    out[key] = isSensitiveKey(key) ? REDACTED : redact(val, seen);
  }
  return out;
}
