import { createParamDecorator, type ExecutionContext } from '@nestjs/common';

import type { AccessTokenPayload } from '../token.service';

/**
 * Injects the verified access-token payload. Populated by JwtAuthGuard, so it
 * is only ever present on a route that actually passed authentication.
 *
 * Note the identity field is `sub`, not `id` — it is a JWT claim.
 */
export const CurrentUser = createParamDecorator(
  (_data: unknown, ctx: ExecutionContext): AccessTokenPayload =>
    ctx.switchToHttp().getRequest<{ user: AccessTokenPayload }>().user,
);
