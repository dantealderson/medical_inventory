import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { IsDateString, IsInt, IsOptional, IsString, IsUUID, Length, Min } from 'class-validator';

export class CreateBatchDto {
  @ApiProperty()
  @IsUUID()
  itemId!: string;

  @ApiProperty({ description: "The supplier's batch number, as printed on the box" })
  @IsString()
  @Length(1, 60)
  batchNumber!: string;

  @ApiProperty({ example: '2027-06-30', description: 'Calendar date, not a timestamp' })
  @IsDateString()
  expiryDate!: string;

  @ApiProperty({ description: 'Quantity received, in boxes' })
  @IsInt()
  @Min(1)
  qtyBoxes!: number;

  @ApiPropertyOptional()
  @IsOptional()
  @IsString()
  @Length(1, 500)
  note?: string;
}
