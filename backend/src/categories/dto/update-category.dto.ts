import { OmitType, PartialType } from '@nestjs/swagger';

import { CreateCategoryDto } from './create-category.dto';

/**
 * parentId is omitted deliberately. Re-parenting changes the level of an
 * entire subtree, and validating only the moved node strands grandchildren at
 * level 4 — unreachable through the client's three-level drill-down, with no
 * error raised anywhere. Delete and recreate instead.
 */
export class UpdateCategoryDto extends PartialType(
  OmitType(CreateCategoryDto, ['parentId'] as const),
) {}
