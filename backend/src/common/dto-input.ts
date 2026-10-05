import { registerDecorator, type ValidationOptions } from 'class-validator';

/** Trims a string, so a name of spaces fails its length check. */
export const trim = ({ value }: { value: unknown }): unknown => (typeof value === 'string' ? value.trim() : value);

/**
 * Trims an optional string and turns a blank one into "not given": a second
 * name left as spaces must not be stored as an empty name that displays
 * blank.
 */
export const trimOrOmit = ({ value }: { value: unknown }): unknown => {
  if (typeof value !== 'string') return value;
  const trimmed = value.trim();
  return trimmed === '' ? undefined : trimmed;
};

/**
 * A plain calendar date, YYYY-MM-DD, that exists. IsDateString let
 * "2027-02-30" through and JavaScript rolled it into March 2: a wrong
 * expiry on medicine, stored without a word.
 */
export function IsCalendarDate(options?: ValidationOptions): PropertyDecorator {
  return (target: object, propertyName: string | symbol) =>
    registerDecorator({
      name: 'isCalendarDate',
      target: target.constructor,
      propertyName: propertyName.toString(),
      options: { message: `${propertyName.toString()} must be a real date as YYYY-MM-DD`, ...options },
      validator: {
        validate(value: unknown): boolean {
          if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
          const [y, m, d] = value.split('-').map(Number);
          const date = new Date(Date.UTC(y, m - 1, d));
          return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d;
        },
      },
    });
}
