import { HttpStatus } from '@nestjs/common';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';

/**
 * The only part of Multer's upload shape the picture endpoints touch.
 *
 * Declared locally rather than widening tsconfig's `types` array to pull in
 * @types/multer's global Express augmentation — one field does not justify
 * changing what every file in the project sees.
 */
export interface UploadedImage {
  buffer?: Buffer;
}

/**
 * Multer options for a picture upload. The 5 MB rule (§10.6) is checked by
 * MediaService with its own message; this cap only stops a huge body from
 * being read into memory first.
 */
export const IMAGE_UPLOAD = { limits: { fileSize: 10 * 1024 * 1024, files: 1 } };

/** The uploaded bytes, or the same refusal as a file that is not a picture. */
export function requireImage(file: UploadedImage | undefined): Buffer {
  if (!file?.buffer) {
    throw new AppException(HttpStatus.BAD_REQUEST, 'INVALID_IMAGE', ERROR_CODES.INVALID_IMAGE);
  }
  return file.buffer;
}
