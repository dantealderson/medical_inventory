/**
 * Calendar dates in the business timezone (spec §7.3, D5).
 *
 * `expiryDate` is a DATE printed on a box. Compared against a UTC instant it
 * is compared against the UTC calendar day, which in Asia/Baghdad (UTC+3) is
 * still yesterday from 00:00 to 03:00 every night. For those three hours the
 * shelf-life filter would admit a batch one day too close to expiry, and
 * nothing would report it. So everything here works in 'YYYY-MM-DD' strings,
 * and SQL compares them with an explicit ::date cast.
 */

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const MS_PER_DAY = 86_400_000;

/** The calendar date of `instant` in `timeZone`, as 'YYYY-MM-DD'. */
export function businessDateOf(instant: Date, timeZone: string): string {
  if (!(instant instanceof Date) || Number.isNaN(instant.getTime())) {
    throw new Error(`businessDateOf: not a valid instant: ${String(instant)}`);
  }
  // formatToParts rather than format(): the parts are stable, while a
  // locale's joined pattern is CLDR data that has changed between ICU
  // releases. An unknown timeZone throws a RangeError here, which is wanted.
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(instant);
  const part = (type: Intl.DateTimeFormatPartTypes): string => {
    const value = parts.find((p) => p.type === type)?.value;
    if (value === undefined) {
      throw new Error(`businessDateOf: no ${type} in ${timeZone} for ${instant.toISOString()}`);
    }
    return value;
  };
  return `${part('year')}-${part('month')}-${part('day')}`;
}

/** Throws unless `isoDate` is a real 'YYYY-MM-DD' calendar date. */
export function assertIsoDate(isoDate: string): void {
  parseIsoDate(isoDate);
}

/**
 * `isoDate` moved by `days` calendar days (negative moves back). Pure
 * arithmetic in UTC, where every day is exactly 86 400 000 ms, so daylight
 * saving in the business zone cannot shift it.
 */
export function addDaysIso(isoDate: string, days: number): string {
  if (!Number.isInteger(days)) {
    // Also catches NaN, which is what Number() makes of a corrupt setting.
    throw new Error(`addDaysIso: days must be an integer, got ${days}`);
  }
  return new Date(parseIsoDate(isoDate) + days * MS_PER_DAY).toISOString().slice(0, 10);
}

/** Midnight UTC of a 'YYYY-MM-DD' date, in epoch milliseconds. */
function parseIsoDate(isoDate: string): number {
  const match = ISO_DATE.exec(isoDate);
  if (match) {
    const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
    const time = Date.UTC(year, month - 1, day);
    const back = new Date(time);
    // Date.UTC rolls 2026-02-30 over to 2026-03-02 without complaint, so the
    // round trip is what rejects a date that does not exist.
    if (
      back.getUTCFullYear() === year &&
      back.getUTCMonth() === month - 1 &&
      back.getUTCDate() === day
    ) {
      return time;
    }
  }
  throw new Error(`Not a 'YYYY-MM-DD' calendar date: ${JSON.stringify(isoDate)}`);
}
