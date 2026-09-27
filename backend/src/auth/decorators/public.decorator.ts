import { SetMetadata } from '@nestjs/common';

export const IS_PUBLIC_KEY = 'isPublic';

/**
 * Opts a route out of authentication.
 *
 * Authentication is deny-by-default (see JwtAuthGuard, registered globally),
 * so every unauthenticated route must say so explicitly. The opposite default
 * means one forgotten decorator silently exposes an endpoint — and nothing
 * fails, which is the worst way for a security bug to behave.
 */
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);
