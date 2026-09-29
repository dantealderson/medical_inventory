import { ApiProperty } from '@nestjs/swagger';
import { IsUUID } from 'class-validator';

export class PinHotDealDto {
  @ApiProperty({ description: 'The item to pin to the front of the client carousel' })
  @IsUUID()
  itemId!: string;
}
