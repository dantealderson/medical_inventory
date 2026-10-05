import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Transform } from 'class-transformer';
import { IsInt, IsOptional, IsString, IsUUID, Length, Max, Min } from 'class-validator';

import { IsCalendarDate, trim } from '../../common/dto-input';

export class CreateBatchDto {
  @ApiProperty()
  @IsUUID()
  itemId!: string;

  @ApiProperty({ description: "The supplier's batch number, as printed on the box" })
  @Transform(trim)
  @IsString()
  @Length(1, 60)
  batchNumber!: string;

  @ApiProperty({ example: '2027-06-30', description: 'Calendar date, not a timestamp' })
  @IsCalendarDate()
  expiryDate!: string;

  @ApiProperty({ description: 'Quantity received, in boxes' })
  @IsInt()
  @Min(1)
  // × at most 10,000 units a box: inside PostgreSQL's integer.
  @Max(100_000)
  qtyBoxes!: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 500)
  note?: string;
}
