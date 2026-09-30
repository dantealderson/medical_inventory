import { Global, Module } from '@nestjs/common';

import { AdminAuditController, AdminAuditService } from './admin-audit.controller';
import { AuditService } from './audit.service';

@Global()
@Module({
  controllers: [AdminAuditController],
  providers: [AuditService, AdminAuditService],
  exports: [AuditService],
})
export class AuditModule {}
