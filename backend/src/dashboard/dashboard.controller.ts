import { Controller, Get } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { Roles } from '../auth/decorators/roles.decorator';
import { DashboardService, type DashboardView } from './dashboard.service';

/** Requirement 10: essentials only. No revenue, profit or sales figures, by design. */
@ApiTags('admin dashboard')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/dashboard')
export class DashboardController {
  constructor(private readonly dashboard: DashboardService) {}

  @Get()
  get(): Promise<DashboardView> {
    return this.dashboard.get();
  }
}
