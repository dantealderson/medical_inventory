import { HttpStatus, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import sharp from 'sharp';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import type { Env } from '../config/env.schema';
import { PrismaService } from '../prisma/prisma.service';

export interface StoredImage {
  url: string;
  thumbnailUrl: string;
}

const ALLOWED_FORMATS = ['jpeg', 'png', 'webp'];

/** Longest side of each variant. Big enough for a phone's detail screen. */
const FULL_MAX = 1200;
const THUMB_MAX = 300;

/**
 * Where pictures are served. Stored as a relative URL (§10.6), so moving the
 * host does not invalidate every item's picture. The thumbnail is the same
 * name with `.thumb.webp`.
 */
const MEDIA_PATH = '/api/v1/media/';
const FILE_NAME = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(\.thumb)?\.webp$/;

/** The media id behind one of our URLs, or null for anything else. */
function idOf(url: string | null | undefined): string | null {
  if (!url?.startsWith(MEDIA_PATH)) return null;
  return FILE_NAME.exec(url.slice(MEDIA_PATH.length))?.[1] ?? null;
}

/**
 * Pictures for items and categories, kept in the database (`media_files`).
 * Free hosts wipe their disk on every restart, and a table is in every backup.
 */
@Injectable()
export class MediaService {
  constructor(
    private readonly config: ConfigService<Env, true>,
    private readonly prisma: PrismaService,
  ) {}

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

    const [full, thumb] = await Promise.all([
      this.variant(buffer, FULL_MAX, 82),
      this.variant(buffer, THUMB_MAX, 75),
    ]);
    const { id } = await this.prisma.mediaFile.create({
      // Prisma 7 takes Bytes as a plain Uint8Array, not a Node Buffer.
      data: { full: new Uint8Array(full), thumb: new Uint8Array(thumb) },
      select: { id: true },
    });

    const url = `${MEDIA_PATH}${id}.webp`;
    return { url, thumbnailUrl: `${MEDIA_PATH}${id}.thumb.webp` };
  }

  /** The bytes behind `<id>.webp` or `<id>.thumb.webp`; null for anything else. */
  async read(file: string): Promise<Buffer | null> {
    const match = FILE_NAME.exec(file);
    if (!match) return null;
    const [, id, thumb] = match;

    if (thumb) {
      const row = await this.prisma.mediaFile.findUnique({ where: { id }, select: { thumb: true } });
      return row ? Buffer.from(row.thumb) : null;
    }
    const row = await this.prisma.mediaFile.findUnique({ where: { id }, select: { full: true } });
    return row ? Buffer.from(row.full) : null;
  }

  /** Deletes the picture behind one of our URLs. Anything else is left alone. */
  async removeByUrl(url: string | null | undefined): Promise<void> {
    const id = idOf(url);
    if (id) await this.prisma.mediaFile.deleteMany({ where: { id } });
  }

  /**
   * `rotate()` applies the EXIF orientation, so a portrait phone photo is not
   * stored sideways. Never enlarged; metadata is stripped (sharp's default).
   */
  private variant(buffer: Buffer, max: number, quality: number): Promise<Buffer> {
    return sharp(buffer)
      .rotate()
      .resize(max, max, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality })
      .toBuffer();
  }
}
