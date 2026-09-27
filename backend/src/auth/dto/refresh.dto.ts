import { ApiProperty } from '@nestjs/swagger';
import { IsString, Length } from 'class-validator';

export class RefreshDto {
  @ApiProperty()
  @IsString()
  @Length(1, 512)
  refreshToken!: string;
}
