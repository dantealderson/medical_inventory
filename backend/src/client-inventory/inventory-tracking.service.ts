import { HttpStatus, Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';

import { AppException } from '../common/errors/app.exception';
import { ERROR_CODES } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';

/**
 * A clinic can stop tracking an item it no longer uses, so it stops showing
 * as «نفد» on every screen and in a weekly alert. The ledger is untouched:
 * this hides the item, it does not change its quantity. A new delivery of
 * the item resumes tracking by itself (creditDelivery), and so does this
 * service's resume. Both are idempotent.
 */
@Injectable()
export class InventoryTrackingService {
  constructor(private readonly prisma: PrismaService) {}

  async stop(clientId: string, itemId: string, now = new Date()): Promise<void> {
    await this.assertHeld(clientId, itemId);
    await this.prisma.clientInventoryItem.updateMany({
      where: { clientId, itemId, trackingStoppedAt: null },
      data: { trackingStoppedAt: now },
    });
  }

  /**
   * Usage is counted from now. Nothing was subtracted while it was stopped,
   * so keeping the old baseline would take the whole stopped period at once.
   */
  async resume(clientId: string, itemId: string, now = new Date()): Promise<void> {
    await this.assertHeld(clientId, itemId);
    await this.prisma.clientInventoryItem.updateMany({
      where: { clientId, itemId, trackingStoppedAt: { not: null } },
      data: {
        trackingStoppedAt: null,
        lastAutoDecrementAt: now,
        fractionalCarry: new Prisma.Decimal(0),
      },
    });
  }

  private async assertHeld(clientId: string, itemId: string): Promise<void> {
    const row = await this.prisma.clientInventoryItem.findUnique({
      where: { clientId_itemId: { clientId, itemId } },
      select: { itemId: true },
    });
    if (!row) {
      throw new AppException(
        HttpStatus.NOT_FOUND,
        'INVENTORY_ITEM_NOT_FOUND',
        ERROR_CODES.INVENTORY_ITEM_NOT_FOUND,
      );
    }
  }
}
