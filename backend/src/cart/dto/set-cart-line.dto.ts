import { ApiProperty } from '@nestjs/swagger';
import { IsInt, Max, Min } from 'class-validator';

export class SetCartLineDto {
  @ApiProperty({ minimum: 0, maximum: 999, description: 'The new quantity in boxes; 0 removes the line' })
  @IsInt()
  @Min(0)
  @Max(999)
  qtyBoxes!: number;
}
