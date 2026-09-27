import { CanActivate, ExecutionContext, HttpStatus, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import type { Role } from '@prisma/client';

import { AppException } from '../../common/errors/app.exception';
import { ERROR_CODES } from '../../common/errors/error-codes';
import { ROLES_KEY } from '../decorators/roles.decorator';
import type { AccessTokenPayload } from '../token.service';

@Injectable()
export class RolesGuard implements CanActivate {
  constructor(private readonly reflector: Reflector) {}

  canActivate(ctx: ExecutionContext): boolean {
    const required = this.reflector.getAllAndOverride<Role[] | undefined>(ROLES_KEY, [
      ctx.getHandler(),
      ctx.getClass(),
    ]);
    if (!required?.length) return true;

    const user = ctx.switchToHttp().getRequest<{ user?: AccessTokenPayload }>().user;

    // The role comes from the verified token, never from a header or body.
    if (!user || !required.includes(user.role)) {
      throw new AppException(HttpStatus.FORBIDDEN, 'FORBIDDEN', ERROR_CODES.FORBIDDEN);
    }
    return true;
  }
}
