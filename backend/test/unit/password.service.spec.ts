import { beforeAll, describe, expect, it } from 'vitest';

import { PasswordService } from '../../src/auth/password.service';

describe('PasswordService', () => {
  let svc: PasswordService;

  beforeAll(() => {
    svc = new PasswordService();
  });

  it('produces a verifiable argon2id hash', async () => {
    const hash = await svc.hash('correct horse battery');
    expect(hash.startsWith('$argon2id$')).toBe(true);
    await expect(svc.verify(hash, 'correct horse battery')).resolves.toBe(true);
  });

  it('rejects a wrong password', async () => {
    const hash = await svc.hash('correct horse battery');
    await expect(svc.verify(hash, 'wrong horse battery')).resolves.toBe(false);
  });

  it('salts: the same password hashes differently every time', async () => {
    const a = await svc.hash('same password');
    const b = await svc.hash('same password');
    expect(a).not.toBe(b);
    await expect(svc.verify(a, 'same password')).resolves.toBe(true);
    await expect(svc.verify(b, 'same password')).resolves.toBe(true);
  });

  it('never stores the plaintext inside the hash', async () => {
    const hash = await svc.hash('supersecret123');
    expect(hash).not.toContain('supersecret123');
  });

  it('returns false rather than throwing on a malformed hash', async () => {
    // A corrupt row must be a failed login, not a 500 that takes the app down.
    await expect(svc.verify('not-a-hash', 'anything')).resolves.toBe(false);
    await expect(svc.verify('', 'anything')).resolves.toBe(false);
  });

  it('handles unicode and long passwords', async () => {
    const pw = 'كلمة السر الطويلة جداً '.repeat(10);
    const hash = await svc.hash(pw);
    await expect(svc.verify(hash, pw)).resolves.toBe(true);
    await expect(svc.verify(hash, `${pw}x`)).resolves.toBe(false);
  });

  it('exposes a DUMMY_HASH that verifies false but is a real argon2id hash', async () => {
    // Used on the login path when the username does not exist, so a missing
    // account costs the same time as a wrong password. If this were not a
    // valid hash, verify() would bail early and reintroduce the timing gap.
    expect(PasswordService.DUMMY_HASH.startsWith('$argon2id$')).toBe(true);
    await expect(svc.verify(PasswordService.DUMMY_HASH, 'anything at all')).resolves.toBe(false);
  });
});
