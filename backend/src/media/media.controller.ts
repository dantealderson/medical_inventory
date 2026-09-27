import {
  Controller, HttpStatus, Post, UploadedFile, UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { ApiBearerAuth, ApiConsumes, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { Roles } from '../auth/decorators/roles.decorator';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { MediaService, type StoredImage } from './media.service';

/**
 * The only part of Multer's upload shape this endpoint touches.
 *
 * Declared locally rather than widening tsconfig's `types` array to pull in
 * @types/multer's global Express augmentation — one field does not justify
 * changing what every file in the project sees.
 */
interface UploadedImage {
  buffer?: Buffer;
  originalname?: string;
  mimetype?: string;
}

@ApiTags('admin/media')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/media')
export class MediaController {
  constructor(private readonly media: MediaService) {}

  @Post()
  @ApiConsumes('multipart/form-data')
  @UseInterceptors(FileInterceptor('file'))
  upload(@UploadedFile() file?: UploadedImage): Promise<StoredImage> {
    if (!file?.buffer) {
      throw new AppException(HttpStatus.BAD_REQUEST, 'INVALID_IMAGE', ERROR_CODES.INVALID_IMAGE);
    }
    return this.media.store(file.buffer);
  }
}
