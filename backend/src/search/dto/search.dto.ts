import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsString, Length, Max, Min } from 'class-validator';

export class SearchDto {
  // Required and non-empty: an empty query must be a 400, not a full-table
  // scan returning the entire catalog.
  @ApiProperty({ example: 'سرنجة' })
  @IsString()
  @Length(1, 100)
  q!: string;

  @ApiPropertyOptional({ default: 30, maximum: 50 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(50)
  limit?: number;
}
