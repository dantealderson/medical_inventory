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
import { CategoriesService, type CategoryNode } from './categories.service';
import { CreateCategoryDto } from './dto/create-category.dto';
import { UpdateCategoryDto } from './dto/update-category.dto';

@ApiTags('admin/categories')
@ApiBearerAuth()
// Controller-level, so a route added here is admin-only by default rather
// than by someone remembering to decorate it.
@Roles(Role.ADMIN)
@Controller('admin/categories')
export class AdminCategoriesController {
  constructor(private readonly categories: CategoriesService) {}

  @Post()
  create(
    @CurrentUser() admin: AccessTokenPayload,
    @Body() dto: CreateCategoryDto,
  ): Promise<CategoryNode> {
    return this.categories.create(admin.sub, dto);
  }

  @Patch(':id')
  update(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @Body() dto: UpdateCategoryDto,
  ): Promise<CategoryNode> {
    return this.categories.update(admin.sub, id, dto);
  }

  /** Uploads a picture (field `file`) and attaches it, replacing any before. */
  @Put(':id/image')
  @ApiConsumes('multipart/form-data')
  @UseInterceptors(FileInterceptor('file', IMAGE_UPLOAD))
  setImage(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
    @UploadedFile() file?: UploadedImage,
  ): Promise<CategoryNode> {
    return this.categories.setImage(admin.sub, id, requireImage(file));
  }

  @Delete(':id/image')
  removeImage(
    @CurrentUser() admin: AccessTokenPayload,
    @Param('id') id: string,
  ): Promise<CategoryNode> {
    return this.categories.removeImage(admin.sub, id);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  remove(@CurrentUser() admin: AccessTokenPayload, @Param('id') id: string): Promise<void> {
    return this.categories.remove(admin.sub, id);
  }
}
