import { Controller, Get, Header, HttpStatus, Param, StreamableFile } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';

import { Public } from '../auth/decorators/public.decorator';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { MediaService } from './media.service';

/**
 * Serves item and category pictures.
 *
 * Public: catalogue photos are not sensitive, the id is an unguessable uuid,
 * and the apps' image widgets send no token. A new upload always gets a new
 * id, so a served file never changes and can be cached for a year.
 */
@ApiTags('media')
@Controller('media')
export class MediaController {
  constructor(private readonly media: MediaService) {}

  @Public()
  @Get(':file')
  @Header('Cache-Control', 'public, max-age=31536000, immutable')
  async serve(@Param('file') file: string): Promise<StreamableFile> {
    const bytes = await this.media.read(file);
    if (!bytes) {
      throw new AppException(HttpStatus.NOT_FOUND, 'NOT_FOUND', ERROR_CODES.NOT_FOUND);
    }
    return new StreamableFile(bytes, { type: 'image/webp' });
  }
}
