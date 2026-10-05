import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import { IsBoolean, IsInt, IsOptional, IsString, IsUUID, Length, Min } from 'class-validator';

import { trim, trimOrOmit } from '../../common/dto-input';

export class CreateCategoryDto {
  @ApiProperty()
  @Transform(trim)
  @IsString()
  @Length(1, 120)
  nameAr!: string;

  @ApiPropertyOptional()
  @Transform(trimOrOmit)
  @IsOptional()
  @IsString()
  @Length(1, 120)
  nameEn?: string;

  @ApiPropertyOptional({ description: 'Omit for a root category' })
  @IsOptional()
  @IsUUID()
  parentId?: string;

  @ApiPropertyOptional({ default: 0 })
  @IsOptional()
  @IsInt()
  @Min(0)
  sortOrder?: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 500)
  imageUrl?: string;

  @ApiPropertyOptional({ default: true })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;

  // `level` is deliberately absent: it is DERIVED from the parent. Accepting
  // it would let a caller declare a level-1 category to be level 3 and walk
  // straight past the depth check. forbidNonWhitelisted rejects it if sent.
}
