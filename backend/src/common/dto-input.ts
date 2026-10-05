import { HttpStatus } from '@nestjs/common';
import { registerDecorator, type ValidationOptions } from 'class-validator';

import { AppException } from './errors/app.exception';
import { ERROR_CODES } from './errors/error-codes';

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

/**
 * An edit may leave a field out, and the validation of a PartialType DTO
 * then skips null as well: a null for a required column reached the
 * database and came back as a 500. Refuses it as the bad input it is.
 */
export function refuseNulls(dto: object, keys: readonly string[]): void {
  const nulls = keys.filter((k) => (dto as Record<string, unknown>)[k] === null);
  if (nulls.length > 0) {
    throw new AppException(
      HttpStatus.BAD_REQUEST,
      'VALIDATION_FAILED',
      ERROR_CODES.VALIDATION_FAILED,
      nulls.map((k) => `${k} must not be null`),
    );
  }
}
