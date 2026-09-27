import { envSchema } from '../../src/config/env.schema';

const valid = {
  NODE_ENV: 'development',
  PORT: '3000',
  DATABASE_URL: 'postgresql://u:p@localhost:5433/db?schema=public',
  BUSINESS_TIMEZONE: 'Asia/Baghdad',
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
    const parsed = envSchema.parse({ DATABASE_URL: valid.DATABASE_URL });
    expect(parsed.NODE_ENV).toBe('development');
    expect(parsed.PORT).toBe(3000);
    expect(parsed.BUSINESS_TIMEZONE).toBe('Asia/Baghdad');
  });

  it('rejects an unknown NODE_ENV', () => {
    expect(() => envSchema.parse({ ...valid, NODE_ENV: 'staging' })).toThrow();
  });
});
