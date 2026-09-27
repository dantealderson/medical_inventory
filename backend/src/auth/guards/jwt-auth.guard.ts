import { CanActivate, ExecutionContext, HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';

import { AppException } from '../../common/errors/app.exception';
import { ERROR_CODES } from '../../common/errors/error-codes';
import type { Env } from '../../config/env.schema';
import { IS_PUBLIC_KEY } from '../decorators/public.decorator';
import type { AccessTokenPayload } from '../token.service';

interface AuthedRequest {
  headers: Record<string, string | string[] | undefined>;
  user?: AccessTokenPayload;
}

/**
 * Verifies the access token and attaches its payload to the request.
 *
 * Registered globally via APP_GUARD, so routes are protected unless they
 * carry @Public(). Deny-by-default is the whole point: a new route added
 * without thinking is closed, not open.
 */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly jwt: JwtService,
    private readonly config: ConfigService<Env, true>,
  ) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      ctx.getHandler(),
      ctx.getClass(),
    ]);
    if (isPublic) return true;

    const req = ctx.switchToHttp().getRequest<AuthedRequest>();
    const raw = req.headers.authorization;
    const header = Array.isArray(raw) ? raw[0] : raw;

    const [scheme, token] = (header ?? '').split(' ');
    if (scheme !== 'Bearer' || !token) throw this.unauthorized();

    try {
      req.user = await this.jwt.verifyAsync<AccessTokenPayload>(token, {
        secret: this.config.get('JWT_ACCESS_SECRET', { infer: true }),
      });
      return true;
    } catch (e) {
      // An EXPIRED token is reported distinctly, because the client is meant
      // to act on it: packages/api_client's AuthInterceptor refreshes only
      // when it sees TOKEN_EXPIRED. Collapsing expiry into a generic
      // UNAUTHORIZED silently disables the whole refresh flow — every session
      // would simply die after 15 minutes.
      //
      // This leaks nothing: the caller already holds the token, so learning
      // that it expired tells them nothing they could not determine by
      // attempting a refresh.
      if (e instanceof Error && e.name === 'TokenExpiredError') {
        throw new AppException(
          HttpStatus.UNAUTHORIZED,
          'TOKEN_EXPIRED',
          ERROR_CODES.TOKEN_EXPIRED,
        );
      }
      // Malformed, wrong signature, wrong secret — indistinguishable, and
      // should stay that way.
      throw this.unauthorized();
    }
  }

  private unauthorized(): AppException {
    return new AppException(HttpStatus.UNAUTHORIZED, 'UNAUTHORIZED', ERROR_CODES.UNAUTHORIZED);
  }
}
