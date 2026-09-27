import { ApiProperty } from '@nestjs/swagger';
import { IsString, Length } from 'class-validator';

export class ResetPasswordDto {
  @ApiProperty({
    minLength: 8,
    description: 'Read to the client over the phone. There is no self-service reset.',
  })
  @IsString()
  @Length(8, 128)
  newPassword!: string;
}
