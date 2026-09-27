import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ArgumentsHost, HttpStatus, HttpException, BadRequestException } from '@nestjs/common';
import { AllExceptionsFilter } from '../../src/common/errors/all-exceptions.filter';
import { AppException } from '../../src/common/errors/app.exception';

function makeHost() {
  const json = vi.fn();
  const status = vi.fn().mockReturnValue({ json });
  const host = {
    switchToHttp: () => ({
      getResponse: () => ({ status }),
      getRequest: () => ({ url: '/api/v1/thing', method: 'GET' }),
    }),
  } as unknown as ArgumentsHost;
  return { host, status, json };
}

describe('AllExceptionsFilter', () => {
  let filter: AllExceptionsFilter;

  beforeEach(() => {
    filter = new AllExceptionsFilter();
    // The filter logs unknown throwables; keep the suite output readable.
    vi.spyOn(filter['logger'], 'error').mockImplementation(() => undefined);
  });

  it('passes through an AppException with its code and Arabic message', () => {
    const { host, status, json } = makeHost();
    filter.catch(new AppException(HttpStatus.NOT_FOUND, 'ITEM_NOT_FOUND', 'الصنف غير موجود'), host);
    expect(status).toHaveBeenCalledWith(404);
    expect(json).toHaveBeenCalledWith({
      statusCode: 404,
      code: 'ITEM_NOT_FOUND',
      messageAr: 'الصنف غير موجود',
    });
  });

  it('includes details when present', () => {
    const { host, json } = makeHost();
    filter.catch(
      new AppException(HttpStatus.BAD_REQUEST, 'VALIDATION_FAILED', 'بيانات غير صحيحة', {
        field: 'qty',
      }),
      host,
    );
    expect(json).toHaveBeenCalledWith(expect.objectContaining({ details: { field: 'qty' } }));
  });

  it('maps a framework HttpException to VALIDATION_FAILED with validation details', () => {
    const { host, status, json } = makeHost();
    filter.catch(new BadRequestException(['qty must be a positive number']), host);
    expect(status).toHaveBeenCalledWith(400);
    expect(json).toHaveBeenCalledWith({
      statusCode: 400,
      code: 'VALIDATION_FAILED',
      messageAr: 'البيانات المدخلة غير صحيحة',
      details: ['qty must be a positive number'],
    });
  });

  it('maps a 404 HttpException to NOT_FOUND', () => {
    const { host, json } = makeHost();
    filter.catch(new HttpException('Nope', HttpStatus.NOT_FOUND), host);
    expect(json).toHaveBeenCalledWith(
      expect.objectContaining({ statusCode: 404, code: 'NOT_FOUND' }),
    );
  });

  it('converts an unknown thrown value into a 500 INTERNAL_ERROR without leaking it', () => {
    const { host, status, json } = makeHost();
    filter.catch(new Error('connection string postgres://user:password@host'), host);
    expect(status).toHaveBeenCalledWith(500);
    expect(json).toHaveBeenCalledWith({
      statusCode: 500,
      code: 'INTERNAL_ERROR',
      messageAr: 'حدث خطأ غير متوقع، يرجى المحاولة لاحقاً',
    });
    // The raw message must never reach the client.
    expect(JSON.stringify(json.mock.calls[0][0])).not.toContain('password');
  });
});
