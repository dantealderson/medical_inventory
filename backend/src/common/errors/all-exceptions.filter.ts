import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { AppException } from './app.exception';
import { ERROR_CODES, type ErrorEnvelope } from './error-codes';

const STATUS_TO_CODE: Record<number, keyof typeof ERROR_CODES> = {
  400: 'VALIDATION_FAILED',
  401: 'UNAUTHORIZED',
  403: 'FORBIDDEN',
  404: 'NOT_FOUND',
  409: 'CONFLICT',
  413: 'PAYLOAD_TOO_LARGE',
};

/** body-parser's own error for a body over its limit: not an HttpException. */
function isTooLarge(exception: unknown): boolean {
  return (exception as { type?: unknown })?.type === 'entity.too.large';
}

interface ResponseLike {
  status: (code: number) => { json: (body: unknown) => void };
}

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger(AllExceptionsFilter.name);

  catch(exception: unknown, host: ArgumentsHost): void {
    const response = host.switchToHttp().getResponse<ResponseLike>();
    response.status(this.statusOf(exception)).json(this.envelope(exception, host));
  }

  private statusOf(exception: unknown): number {
    if (isTooLarge(exception)) return HttpStatus.PAYLOAD_TOO_LARGE;
    return exception instanceof HttpException
      ? exception.getStatus()
      : HttpStatus.INTERNAL_SERVER_ERROR;
  }

  private envelope(exception: unknown, host: ArgumentsHost): ErrorEnvelope {
    if (exception instanceof AppException) {
      const body: ErrorEnvelope = {
        statusCode: exception.getStatus(),
        code: exception.code,
        messageAr: exception.messageAr,
      };
      if (exception.details !== undefined) body.details = exception.details;
      return body;
    }

    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const code = STATUS_TO_CODE[status] ?? 'INTERNAL_ERROR';
      const body: ErrorEnvelope = { statusCode: status, code, messageAr: ERROR_CODES[code] };
      const details = this.validationDetails(exception);
      if (details !== undefined) body.details = details;
      return body;
    }

    if (isTooLarge(exception)) {
      return {
        statusCode: HttpStatus.PAYLOAD_TOO_LARGE,
        code: 'PAYLOAD_TOO_LARGE',
        messageAr: ERROR_CODES.PAYLOAD_TOO_LARGE,
      };
    }

    // Unknown throwable: log it server-side in full, tell the client nothing.
    // Raw messages can contain connection strings, tokens and stack traces.
    const req = host.switchToHttp().getRequest<{ method?: string; url?: string }>();
    this.logger.error(`Unhandled ${req?.method} ${req?.url}`, exception as Error);
    return {
      statusCode: HttpStatus.INTERNAL_SERVER_ERROR,
      code: 'INTERNAL_ERROR',
      messageAr: ERROR_CODES.INTERNAL_ERROR,
    };
  }

  /** class-validator failures arrive as { message: string[] } — surface them. */
  private validationDetails(exception: HttpException): unknown {
    const res = exception.getResponse();
    if (typeof res === 'object' && res !== null && 'message' in res) {
      const message = (res as { message: unknown }).message;
      if (Array.isArray(message)) return message;
    }
    return undefined;
  }
}
