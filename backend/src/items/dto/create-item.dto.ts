import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import {
  IsBoolean, IsInt, IsNumberString, IsOptional, IsString, IsUUID, Length, Matches, Min,
  ValidateIf,
} from 'class-validator';

export class CreateItemDto {
  // At least one name is required. ValidateIf makes nameAr mandatory only when
  // nameEn is absent and vice versa — so either alone is accepted and neither
  // is not. A CHECK constraint backs this at the database level.
  @ApiPropertyOptional()
  @ValidateIf((o: CreateItemDto) => !o.nameEn)
  @IsString()
  @Length(1, 200)
  nameAr?: string;

  @ApiPropertyOptional()
  @ValidateIf((o: CreateItemDto) => !o.nameAr)
  @IsString()
  @Length(1, 200)
  nameEn?: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 2000)
  description?: string;

  @ApiProperty()
  @IsUUID()
  categoryId!: string;

  @ApiProperty({ description: 'Base units in one box, e.g. 100 syringes' })
  @IsInt()
  @Min(1)
  unitsPerBox!: number;

  @ApiProperty({ example: 'سرنجة', description: 'What one base unit is called' })
  @IsString()
  @Length(1, 60)
  unitLabelAr!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 60)
  unitLabelEn?: string;

  // A string, not a number: binary floats cannot represent money exactly, and
  // Prisma's Decimal accepts a string directly.
  @ApiProperty({ example: '12.50' })
  @IsNumberString()
  @Matches(/^\d{1,10}(\.\d{1,2})?$/, { message: 'pricePerBox must have at most 2 decimals' })
  pricePerBox!: string;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 500)
  imageUrl?: string;

  // Entered in BOXES, stored in UNITS (§7.6). One conversion, in the service.
  @ApiPropertyOptional({ description: 'Minimum stock in boxes; stored as units' })
  @IsOptional()
  @IsInt()
  @Min(0)
  minQtyBoxes?: number;

  @ApiPropertyOptional({ default: true })
  @IsOptional()
  @IsBoolean()
  isActive?: boolean;
}
