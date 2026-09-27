/**
 * Spec §9. Every tunable in the system. Code must read these through
 * SettingsService, never import the literal — the whole point is that an
 * admin can change them at runtime.
 */
export const SETTING_DEFAULTS = Object.freeze({
  'stock.redDaysOfCover': 7,
  'stock.yellowDaysOfCover': 21,
  'estimation.purchaseWindowDays': 90,
  'estimation.minPurchaseDays': 30,
  'estimation.minMeasureDays': 7,
  'estimation.measurePairWindowDays': 180,
  'estimation.maxCatchUpDays': 30,
  'alerts.repeatAfterDays': 7,
  'expiry.warnDaysAhead': 60,
  'expiry.minShelfLifeOnDeliveryDays': 30,
  'hotDeals.rotationSeconds': 4,
  'hotDeals.frequentWindowDays': 60,
  'hotDeals.newItemDays': 30,
  'hotDeals.maxEntries': 10,
  'business.timezone': 'Asia/Baghdad',
} as const);

export type SettingKey = keyof typeof SETTING_DEFAULTS;

/**
 * Widen a literal back to its primitive.
 *
 * `as const` above is what gives us the key union and readonly defaults, but
 * it also types each value as the literal it happens to default to — so
 * `SettingValue<'stock.redDaysOfCover'>` would be `7`, and `set()` could only
 * ever assign 7 to it. That defeats the entire purpose of a settings table.
 *
 * Widening keeps the useful half of the guarantee: a numeric setting still
 * rejects a string, and `business.timezone` still rejects a number.
 */
type Widen<T> = T extends number
  ? number
  : T extends string
    ? string
    : T extends boolean
      ? boolean
      : T;

export type SettingValue<K extends SettingKey> = Widen<(typeof SETTING_DEFAULTS)[K]>;

export const SETTING_KEYS = Object.keys(SETTING_DEFAULTS) as SettingKey[];
