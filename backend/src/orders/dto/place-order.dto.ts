import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsOptional, IsString, Length } from 'class-validator';

export class PlaceOrderDto {
  @ApiPropertyOptional({ maxLength: 500, description: 'A note for the supplier' })
  @IsOptional()
  @IsString()
  @Length(1, 500)
  note?: string;
}
