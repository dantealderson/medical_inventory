import { describe, it, expect } from 'vitest';
import { envSchema } from '../../src/config/env.schema';

const valid = {
  NODE_ENV: 'development',
  PORT: '3000',
  DATABASE_URL: 'postgresql://u:p@localhost:5433/db?schema=public',
  BUSINESS_TIMEZONE: 'Asia/Baghdad',
  JWT_ACCESS_SECRET: 'a'.repeat(48),
  JWT_REFRESH_SECRET: 'b'.repeat(48),
};

describe('envSchema', () => {
  it('accepts a valid environment and coerces PORT to a number', () => {
    const parsed = envSchema.parse(valid);
    expect(parsed.PORT).toBe(3000);
    expect(typeof parsed.PORT).toBe('number');
  });

  it('rejects a missing DATABASE_URL', () => {
    const { DATABASE_URL, ...without } = valid;
    expect(() => envSchema.parse(without)).toThrow();
  });

  it('rejects a DATABASE_URL that is not a URL', () => {
    expect(() => envSchema.parse({ ...valid, DATABASE_URL: 'not-a-url' })).toThrow();
  });

  it('applies defaults for NODE_ENV, PORT and BUSINESS_TIMEZONE', () => {
    const parsed = envSchema.parse({
      DATABASE_URL: valid.DATABASE_URL,
      JWT_ACCESS_SECRET: valid.JWT_ACCESS_SECRET,
      JWT_REFRESH_SECRET: valid.JWT_REFRESH_SECRET,
    });
    expect(parsed.NODE_ENV).toBe('development');
    expect(parsed.PORT).toBe(3000);
    expect(parsed.BUSINESS_TIMEZONE).toBe('Asia/Baghdad');
  });

  it('rejects an unknown NODE_ENV', () => {
    expect(() => envSchema.parse({ ...valid, NODE_ENV: 'staging' })).toThrow();
  });
});

describe('envSchema JWT secrets', () => {
  const base = {
    DATABASE_URL: 'postgresql://u:p@localhost:5433/db?schema=public',
    JWT_ACCESS_SECRET: 'a'.repeat(48),
    JWT_REFRESH_SECRET: 'b'.repeat(48),
  };

  it('accepts two distinct strong secrets', () => {
    expect(() => envSchema.parse(base)).not.toThrow();
  });

  it('rejects a missing secret', () => {
    const { JWT_ACCESS_SECRET, ...without } = base;
    expect(() => envSchema.parse(without)).toThrow();
  });

  it('rejects a short secret', () => {
    expect(() => envSchema.parse({ ...base, JWT_ACCESS_SECRET: 'tooshort' })).toThrow();
  });

  it('rejects the .env.example placeholder even though it is long enough', () => {
    // 57 chars, so min(32) alone would let it through — and it is published
    // in the repository, making every token forgeable.
    const placeholder = 'replace-me-with-48-random-bytes-base64url-at-least-32-chars';
    expect(placeholder.length).toBeGreaterThan(32);
    expect(() => envSchema.parse({ ...base, JWT_ACCESS_SECRET: placeholder })).toThrow();
  });

  it('rejects reusing one secret for both', () => {
    const same = 'c'.repeat(48);
    expect(() =>
      envSchema.parse({ ...base, JWT_ACCESS_SECRET: same, JWT_REFRESH_SECRET: same }),
    ).toThrow();
  });
});
