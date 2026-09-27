import { describe, expect, it } from 'vitest';

import { REDACTED, redact } from '../../src/audit/audit-redaction';

describe('redact', () => {
  it('replaces passwordHash at the top level', () => {
    expect(redact({ id: 'u1', passwordHash: '$argon2id$abc' })).toEqual({
      id: 'u1',
      passwordHash: REDACTED,
    });
  });

  it('replaces sensitive keys nested at any depth', () => {
    const out = redact({ a: { b: { tokenHash: 'deadbeef', keep: 1 } } }) as {
      a: { b: { tokenHash: string; keep: number } };
    };
    expect(out.a.b.tokenHash).toBe(REDACTED);
    expect(out.a.b.keep).toBe(1);
  });

  it('redacts inside arrays', () => {
    const out = redact({ devices: [{ fcmToken: 'tok' }, { fcmToken: 'tok2' }] }) as {
      devices: { fcmToken: string }[];
    };
    expect(out.devices[0].fcmToken).toBe(REDACTED);
    expect(out.devices[1].fcmToken).toBe(REDACTED);
  });

  it('matches case-insensitively and on partial names', () => {
    const out = redact({
      PasswordHash: 'x',
      refreshTokenHash: 'y',
      accessToken: 'z',
      SECRET_KEY: 'w',
    }) as Record<string, string>;
    expect(out.PasswordHash).toBe(REDACTED);
    expect(out.refreshTokenHash).toBe(REDACTED);
    expect(out.accessToken).toBe(REDACTED);
    expect(out.SECRET_KEY).toBe(REDACTED);
  });

  it('is key-based only — it cannot see a secret hidden in free text', () => {
    // Documented limitation, asserted so nobody assumes otherwise: callers
    // must not put credentials in `note`.
    expect(redact({ note: 'reset done' })).toEqual({ note: 'reset done' });
  });

  it('leaves non-sensitive data untouched', () => {
    const input = { username: 'lab1', status: 'ACTIVE', phone: '07700000000' };
    expect(redact(input)).toEqual(input);
  });

  it('passes through primitives and null', () => {
    expect(redact(null)).toBeNull();
    expect(redact(42)).toBe(42);
    expect(redact('x')).toBe('x');
    expect(redact(undefined)).toBeUndefined();
  });

  it('does not mutate its input', () => {
    const input = { passwordHash: 'secret' };
    redact(input);
    expect(input.passwordHash).toBe('secret');
  });

  it('survives a cyclic object without hanging', () => {
    const a: Record<string, unknown> = { passwordHash: 'x' };
    a.self = a;
    const out = redact(a) as Record<string, unknown>;
    expect(out.passwordHash).toBe(REDACTED);
    expect(out.self).toBe('[CIRCULAR]');
  });

  it('handles a Date without destructuring it into an object', () => {
    // Prisma hands back Date instances; turning one into {} would silently
    // destroy audit timestamps.
    const d = new Date('2026-09-27T10:00:00.000Z');
    const out = redact({ createdAt: d }) as { createdAt: unknown };
    expect(out.createdAt).toBeInstanceOf(Date);
    expect((out.createdAt as Date).toISOString()).toBe('2026-09-27T10:00:00.000Z');
  });

  it('redacts a sensitive key even when its value is an object', () => {
    const out = redact({ token: { nested: 'still secret' } }) as Record<string, unknown>;
    expect(out.token).toBe(REDACTED);
  });
});
