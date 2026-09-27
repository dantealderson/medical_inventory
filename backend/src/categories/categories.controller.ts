import { Controller, Get, Param } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { CategoriesService, type CategoryNode } from './categories.service';

@ApiTags('categories')
@ApiBearerAuth()
@Controller('categories')
export class CategoriesController {
  constructor(private readonly categories: CategoriesService) {}

  @Get()
  tree(): Promise<CategoryNode[]> {
    return this.categories.tree();
  }

  @Get(':id')
  findOne(@Param('id') id: string): Promise<CategoryNode> {
    return this.categories.findOne(id);
  }
}
