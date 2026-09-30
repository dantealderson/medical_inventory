import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Post,
  Query,
} from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { ListNotificationsDto } from './dto/list-notifications.dto';
import { RegisterDeviceDto } from './dto/register-device.dto';
import {
  type NotificationPage,
  type NotificationView,
  NotificationsService,
} from './notifications.service';

/**
 * The signed-in user's own notifications, whatever their role: a clinic's
 * alerts and order news, an admin's new orders and out-of-stock clinics.
 * The user is always the token's, never an id in the path.
 */
@ApiTags('notifications')
@ApiBearerAuth()
@Controller('notifications')
export class NotificationsController {
  constructor(private readonly notifications: NotificationsService) {}

  @Get()
  list(
    @CurrentUser() user: AccessTokenPayload,
    @Query() query: ListNotificationsDto,
  ): Promise<NotificationPage> {
    return this.notifications.list(user.sub, query);
  }

  @Get('unread-count')
  async unreadCount(@CurrentUser() user: AccessTokenPayload): Promise<{ count: number }> {
    return { count: await this.notifications.unreadCount(user.sub) };
  }

  @Post('read-all')
  @HttpCode(HttpStatus.OK)
  markAllRead(@CurrentUser() user: AccessTokenPayload): Promise<{ updated: number }> {
    return this.notifications.markAllRead(user.sub);
  }

  @Post(':id/read')
  @HttpCode(HttpStatus.OK)
  markRead(
    @CurrentUser() user: AccessTokenPayload,
    @Param('id') id: string,
  ): Promise<NotificationView> {
    return this.notifications.markRead(user.sub, id);
  }
}

/**
 * Phones that can receive push. A token belongs to whoever registered it
 * last: a clinic's shared phone moves between accounts as people sign in.
 */
@ApiTags('notifications')
@ApiBearerAuth()
@Controller('devices')
export class DevicesController {
  constructor(private readonly prisma: PrismaService) {}

  @Post()
  @HttpCode(HttpStatus.NO_CONTENT)
  async register(@CurrentUser() user: AccessTokenPayload, @Body() dto: RegisterDeviceDto): Promise<void> {
    const now = new Date();
    await this.prisma.deviceToken.upsert({
      where: { fcmToken: dto.fcmToken },
      create: { userId: user.sub, fcmToken: dto.fcmToken, platform: dto.platform, lastSeenAt: now },
      update: { userId: user.sub, platform: dto.platform, lastSeenAt: now },
    });
  }

  @Delete(':fcmToken')
  @HttpCode(HttpStatus.NO_CONTENT)
  async unregister(
    @CurrentUser() user: AccessTokenPayload,
    @Param('fcmToken') fcmToken: string,
  ): Promise<void> {
    const { count } = await this.prisma.deviceToken.deleteMany({
      where: { fcmToken, userId: user.sub },
    });
    if (count === 0) {
      throw new AppException(HttpStatus.NOT_FOUND, 'DEVICE_NOT_FOUND', ERROR_CODES.DEVICE_NOT_FOUND);
    }
  }
}
