import { ApiProperty } from '@nestjs/swagger';
import { IsString, Length } from 'class-validator';

export class LoginDto {
  @ApiProperty({ example: 'lab_alnoor' })
  @IsString()
  @Length(1, 32)
  username!: string;

  @ApiProperty()
  @IsString()
  @Length(1, 128)
  password!: string;
}
