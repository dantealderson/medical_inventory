import { Injectable, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaPg } from '@prisma/adapter-pg';
import { PrismaClient } from '@prisma/client';

import type { Env } from '../config/env.schema';

@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  constructor(config: ConfigService<Env, true>) {
    // Prisma 7 requires a driver adapter; the datasource block in
    // schema.prisma no longer carries a url. Taking the connection string
    // from ConfigService rather than letting Prisma read process.env itself
    // means it has already passed the boot-time zod validation.
    super({ adapter: new PrismaPg(config.get('DATABASE_URL', { infer: true })) });
  }

  async onModuleInit(): Promise<void> {
    await this.$connect();
  }

  async onModuleDestroy(): Promise<void> {
    await this.$disconnect();
  }
}
