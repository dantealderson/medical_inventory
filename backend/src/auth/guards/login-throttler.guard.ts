import { Injectable } from '@nestjs/common';
import { ThrottlerGuard } from '@nestjs/throttler';

/**
 * Login attempts counted per username and address, not per address alone.
 *
 * Behind the dev tunnel or a host's proxy every clinic arrives from the same
 * address, so a per-address count let one clinic's typos lock every other
 * clinic out of signing in. Guessing one account's password is limited just
 * as before.
 */
@Injectable()
export class LoginThrottlerGuard extends ThrottlerGuard {
  protected override async getTracker(req: Record<string, unknown>): Promise<string> {
    const body = req.body as { username?: unknown } | undefined;
    const username = typeof body?.username === 'string' ? body.username.trim().toLowerCase() : '';
    return `${await super.getTracker(req)}|${username}`;
  }
}
