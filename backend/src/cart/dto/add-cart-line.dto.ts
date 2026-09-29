import { ApiProperty } from '@nestjs/swagger';
import { IsInt, IsUUID, Max, Min } from 'class-validator';

export class AddCartLineDto {
  @ApiProperty()
  @IsUUID()
  itemId!: string;

  @ApiProperty({ minimum: 1, maximum: 999, description: 'Boxes to ADD to the line' })
  @IsInt()
  @Min(1)
  @Max(999)
  qtyBoxes!: number;
}
