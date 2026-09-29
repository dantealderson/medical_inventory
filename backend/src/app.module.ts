import { Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';

import { AllocationModule } from './allocation/allocation.module';
import { AuditModule } from './audit/audit.module';
import { AuthModule } from './auth/auth.module';
import { CartModule } from './cart/cart.module';
import { CategoriesModule } from './categories/categories.module';
import { ClientInventoryModule } from './client-inventory/client-inventory.module';
import { EstimationModule } from './estimation/estimation.module';
import { ItemsModule } from './items/items.module';
import { MediaModule } from './media/media.module';
import { OrdersModule } from './orders/orders.module';
import { SearchModule } from './search/search.module';
import { WarehouseModule } from './warehouse/warehouse.module';
import { JwtAuthGuard } from './auth/guards/jwt-auth.guard';
import { RolesGuard } from './auth/guards/roles.guard';
import { AppConfigModule } from './config/config.module';
import { HealthModule } from './health/health.module';
import { HotDealsModule } from './hot-deals/hot-deals.module';
import { PrismaModule } from './prisma/prisma.module';
import { SettingsModule } from './settings/settings.module';
import { UsersModule } from './users/users.module';

@Module({
  imports: [
    AppConfigModule,
    PrismaModule,
    SettingsModule,
    AuditModule,
    AuthModule,
    UsersModule,
    CategoriesModule,
    ItemsModule,
    MediaModule,
    WarehouseModule,
    SearchModule,
    HealthModule,
    AllocationModule,
    CartModule,
    ClientInventoryModule,
    OrdersModule,
    HotDealsModule,
    EstimationModule,
  ],
  providers: [
    // Order matters: JwtAuthGuard populates request.user, which RolesGuard
    // then reads. Reversing them makes every role check see an undefined
    // user and reject everything.
    //
    // Both are global so authentication is DENY-BY-DEFAULT. A route added
    // without thinking about auth is closed; opening one requires writing
    // @Public() deliberately.
    { provide: APP_GUARD, useClass: JwtAuthGuard },
    { provide: APP_GUARD, useClass: RolesGuard },
  ],
})
export class AppModule {}
