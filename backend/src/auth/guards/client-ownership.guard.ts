import { CanActivate, ExecutionContext, HttpStatus, Injectable } from '@nestjs/common';
import { Role } from '@prisma/client';

import { AppException } from '../../common/errors/app.exception';
import { ERROR_CODES } from '../../common/errors/error-codes';
import type { AccessTokenPayload } from '../token.service';

/**
 * A client may only ever touch their own resources. Admins bypass.
 *
 * Enforced here rather than by the UI hiding a button: the UI is not a
 * security boundary. Every later phase — cart, orders, inventory, stock
 * counts — hangs off this single rule, so it lives in one place that every
 * such route opts into.
 */
@Injectable()
export class ClientOwnershipGuard implements CanActivate {
  canActivate(ctx: ExecutionContext): boolean {
    const req = ctx.switchToHttp().getRequest<{
      user?: AccessTokenPayload;
      params?: Record<string, string>;
    }>();

    const user = req.user;
    if (!user) {
      throw new AppException(HttpStatus.UNAUTHORIZED, 'UNAUTHORIZED', ERROR_CODES.UNAUTHORIZED);
    }
    if (user.role === Role.ADMIN) return true;

    // `sub` is the JWT subject claim — the user id.
    const target = req.params?.clientId ?? req.params?.id;
    if (target && target !== user.sub) {
      throw new AppException(HttpStatus.FORBIDDEN, 'FORBIDDEN', ERROR_CODES.FORBIDDEN);
    }
    return true;
  }
}
