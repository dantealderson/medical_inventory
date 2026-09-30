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

/**
 * Whole calendar days from `earlier` to `later`, both 'YYYY-MM-DD' (negative
 * when `later` comes first). Phase 4 measures every "day" this way, as a
 * difference of business dates, never of instants: a run at 00:30 Baghdad is
 * a new day even though only an hour has passed since 23:30.
 */
export function diffDaysIso(later: string, earlier: string): number {
  return Math.round((parseIsoDate(later) - parseIsoDate(earlier)) / MS_PER_DAY);
}

/**
 * The instant a business day begins: local midnight of `isoDate` in
 * `timeZone`. For filtering stored instants by a calendar day the admin
 * picked, e.g. "audit entries on 10 January" in Baghdad starts at 21:00Z on
 * the 9th.
 *
 * Found by asking what local time UTC midnight of that date is, and moving
 * back by that offset — then correcting once more, so a zone whose offset
 * changes that day (daylight saving) still lands on local midnight.
 */
export function startOfBusinessDay(isoDate: string, timeZone: string): Date {
  const utcMidnight = parseIsoDate(isoDate);
  let guess = utcMidnight - offsetMs(utcMidnight, timeZone);
  guess = utcMidnight - offsetMs(guess, timeZone);
  return new Date(guess);
}

/** How far `timeZone` is ahead of UTC at `instantMs`. */
function offsetMs(instantMs: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hourCycle: 'h23',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).formatToParts(new Date(instantMs));
  const get = (type: Intl.DateTimeFormatPartTypes) => Number(parts.find((p) => p.type === type)?.value);
  const asUtc = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second'));
  return asUtc - Math.floor(instantMs / 1000) * 1000;
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
