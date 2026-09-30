import {
  Body,
  Controller,
  Delete,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
  Put,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { ApiBearerAuth, ApiConsumes, ApiTags } from '@nestjs/swagger';
import { Role } from '@prisma/client';

import { CurrentUser } from '../auth/decorators/current-user.decorator';
import { Roles } from '../auth/decorators/roles.decorator';
import type { AccessTokenPayload } from '../auth/token.service';
import { IMAGE_UPLOAD, requireImage, type UploadedImage } from '../media/upload';
import { CreateItemDto } from './dto/create-item.dto';
import { UpdateItemDto } from './dto/update-item.dto';
import { ItemsService, type ItemView } from './items.service';

@ApiTags('admin/items')
@ApiBearerAuth()
@Roles(Role.ADMIN)
@Controller('admin/items')
export class AdminItemsController {
  constructor(private readonly items: ItemsService) {}

  @Post()
  create(@CurrentUser() admin: AccessTokenPayload, @Body() dto: CreateItemDto): Promise<ItemView> {
    return this.items.create(admin.sub, dto);
  }

  @Patch(':id')
  update(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: UpdateItemDto,
  ): Promise<ItemView> {
    return this.items.update(admin.sub, id, dto);
  }

  /** Uploads a picture (field `file`) and attaches it, replacing any before. */
  @Put(':id/image')
  @ApiConsumes('multipart/form-data')
  @UseInterceptors(FileInterceptor('file', IMAGE_UPLOAD))
  setImage(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @UploadedFile() file?: UploadedImage,
  ): Promise<ItemView> {
    return this.items.setImage(admin.sub, id, requireImage(file));
  }

  @Delete(':id/image')
  removeImage(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<ItemView> {
    return this.items.removeImage(admin.sub, id);
  }

  /** Deactivates. Order history must keep resolving its items. */
  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  deactivate(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<void> {
    return this.items.deactivate(admin.sub, id);
  }
}
