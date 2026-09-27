import { Controller, Get } from '@nestjs/common';

import { Public } from '../auth/decorators/public.decorator';
import { PrismaService } from '../prisma/prisma.service';

@Controller('health')
export class HealthController {
  constructor(private readonly prisma: PrismaService) {}

  /** Public: a liveness probe that needs credentials is not a liveness probe. */
  @Public()
  @Get()
  async check(): Promise<{ status: string; database: string }> {
    // A trivial round-trip proves the pool is live, not merely constructed.
    await this.prisma.$queryRaw`SELECT 1`;
    return { status: 'ok', database: 'up' };
  }
}
