import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
} from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { CartService, type CartView } from './cart.service';
import { AddCartLineDto } from './dto/add-cart-line.dto';
import { SetCartLineDto } from './dto/set-cart-line.dto';

/**
 * The signed-in clinic's own cart. The cart is found by the token's user id,
 * never by an id in the path or body. That is the ownership rule (D10), and
 * it is why no ClientOwnershipGuard is needed. @Roles keeps an admin token
 * from creating a cart of its own.
 */
@ApiTags('cart')
@ApiBearerAuth()
@Roles(Role.CLIENT)
@Controller('cart')
export class CartController {
  constructor(private readonly cart: CartService) {}

  @Get()
  get(@CurrentUser() user: AccessTokenPayload): Promise<CartView> {
    return this.cart.get(user.sub);
  }

  /** Adds to the line (the + button). 200, not 201: the cart and line may already exist. */
  @Post('lines')
  @HttpCode(HttpStatus.OK)
  addLine(@CurrentUser() user: AccessTokenPayload, @Body() dto: AddCartLineDto): Promise<CartView> {
    return this.cart.addLine(user.sub, dto);
  }

  @Patch('lines/:itemId')
  setLine(
    @CurrentUser() user: AccessTokenPayload,
    @Param('itemId') itemId: string,
    @Body() dto: SetCartLineDto,
  ): Promise<CartView> {
    return this.cart.setLine(user.sub, itemId, dto);
  }

  @Delete('lines/:itemId')
  @HttpCode(HttpStatus.NO_CONTENT)
  removeLine(
    @CurrentUser() user: AccessTokenPayload,
    @Param('itemId') itemId: string,
  ): Promise<void> {
    return this.cart.removeLine(user.sub, itemId);
  }

  @Delete()
  @HttpCode(HttpStatus.NO_CONTENT)
  clear(@CurrentUser() user: AccessTokenPayload): Promise<void> {
    return this.cart.clear(user.sub);
  }
}
