import { randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import sharp from 'sharp';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import type { Env } from '../config/env.schema';

export interface StoredImage {
  url: string;
  thumbnailUrl: string;
}

const ALLOWED_FORMATS = ['jpeg', 'png', 'webp'];

@Injectable()
export class MediaService {
  constructor(private readonly config: ConfigService<Env, true>) {}

  async store(buffer: Buffer): Promise<StoredImage> {
    const maxBytes = this.config.get('MAX_UPLOAD_BYTES', { infer: true });
    if (buffer.byteLength > maxBytes) {
      throw new AppException(
        HttpStatus.BAD_REQUEST,
        'IMAGE_TOO_LARGE',
        ERROR_CODES.IMAGE_TOO_LARGE,
      );
    }

    // Decode the BYTES rather than trusting the filename. An extension check
    // is bypassed by renaming a shell script to .png; sharp fails on anything
    // that is not genuinely an image.
    let meta: sharp.Metadata;
    try {
      meta = await sharp(buffer).metadata();
    } catch {
      throw new AppException(HttpStatus.BAD_REQUEST, 'INVALID_IMAGE', ERROR_CODES.INVALID_IMAGE);
    }

    if (!meta.format || !ALLOWED_FORMATS.includes(meta.format)) {
      throw new AppException(HttpStatus.BAD_REQUEST, 'INVALID_IMAGE', ERROR_CODES.INVALID_IMAGE);
    }

    const dir = this.config.get('UPLOAD_DIR', { infer: true });
    await mkdir(dir, { recursive: true });

    // A generated name, never the client's. An uploaded "../../.env" is a path
    // traversal, and a repeated name silently overwrites someone else's image.
    const id = randomUUID();
    const full = `${id}.webp`;
    const thumb = `${id}.thumb.webp`;

    await writeFile(join(dir, full), await sharp(buffer).webp({ quality: 82 }).toBuffer());
    await writeFile(
      join(dir, thumb),
      await sharp(buffer).resize(200, 200, { fit: 'inside' }).webp({ quality: 75 }).toBuffer(),
    );

    // Relative URLs, so moving the host does not invalidate every stored path.
    return { url: `/uploads/${full}`, thumbnailUrl: `/uploads/${thumb}` };
  }
}
