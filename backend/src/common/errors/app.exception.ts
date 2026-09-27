import { HttpException, HttpStatus } from '@nestjs/common';

/**
 * Domain exception. Carries a stable machine code and a display-ready Arabic
 * message so the filter never has to guess how to present a failure.
 */
export class AppException extends HttpException {
  constructor(
    status: HttpStatus,
    public readonly code: string,
    public readonly messageAr: string,
    public readonly details?: unknown,
  ) {
    super({ code, messageAr, details }, status);
  }
}
