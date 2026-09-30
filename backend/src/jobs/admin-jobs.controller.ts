import { Controller, Get, HttpCode, HttpStatus, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';
import { Type } from 'class-transformer';
import { IsInt, IsOptional, Max, Min } from 'class-validator';

import { Roles } from '../auth/decorators/roles.decorator';
import { type JobRunView, NightlyJobsService } from './nightly-jobs.service';

export class ListJobRunsDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}

/** Run the nightly jobs now, and read the run log. Admin only. */
@ApiTags('admin jobs')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/jobs')
export class AdminJobsController {
  constructor(private readonly nightly: NightlyJobsService) {}

  @Post('nightly')
  @HttpCode(HttpStatus.OK)
  async runNightly(): Promise<{ runs: JobRunView[] }> {
    return { runs: await this.nightly.runAll(new Date()) };
  }

  @Get('runs')
  async runs(@Query() query: ListJobRunsDto): Promise<{ items: JobRunView[] }> {
    return { items: await this.nightly.recentRuns(query.limit ?? 30) };
  }
}
