import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';

/**
 * One item as the clinic found it: whole boxes plus loose units. Converted to
 * units on the server with the item's box size, never by the app.
 */
export class StockCountLineDto {
  @ApiProperty()
  @IsUUID()
  itemId!: string;

  @ApiProperty({ minimum: 0, maximum: 99_999 })
  @IsInt()
  @Min(0)
  @Max(99_999)
  boxes!: number;

  @ApiProperty({ minimum: 0, maximum: 999_999, description: 'Loose units, outside whole boxes' })
  @IsInt()
  @Min(0)
  @Max(999_999)
  units!: number;
}

export class StockCountDto {
  @ApiProperty({ type: [StockCountLineDto] })
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(500)
  @ValidateNested({ each: true })
  @Type(() => StockCountLineDto)
  lines!: StockCountLineDto[];

  @ApiPropertyOptional({ maxLength: 500 })
  @IsOptional()
  @IsString()
  @MaxLength(500)
  note?: string;
}
