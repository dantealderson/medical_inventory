import { ApiProperty } from '@nestjs/swagger';
import { IsString, Length } from 'class-validator';

export class DeleteAccountDto {
  @ApiProperty({ description: 'The account’s own password: deleting cannot be undone.' })
  @IsString()
  @Length(1, 128)
  password!: string;
}
