import { ApiProperty } from '@nestjs/swagger';
import { IsOptional, IsString, Length, Matches } from 'class-validator';

export class RegisterDto {
  @ApiProperty({ example: 'lab_alnoor' })
  @IsString()
  @Length(3, 32)
  // Lowercase letters, digits, underscore. Keeps usernames unambiguous to
  // read aloud over the phone, which is how a password reset starts when
  // there is no self-service recovery.
  @Matches(/^[a-z0-9_]+$/, {
    message: 'username must be lowercase letters, digits or underscore',
  })
  username!: string;

  @ApiProperty({ minLength: 8 })
  @IsString()
  @Length(8, 128)
  password!: string;

  @ApiProperty({ required: false })
  @IsOptional()
  @IsString()
  @Length(2, 120)
  clinicName?: string;

  @ApiProperty({ required: false })
  @IsOptional()
  @IsString()
  @Length(2, 120)
  contactName?: string;

  @ApiProperty({ required: false, description: 'Contact only — never an auth factor' })
  @IsOptional()
  @IsString()
  @Length(6, 20)
  phone?: string;

  @ApiProperty({ required: false })
  @IsOptional()
  @IsString()
  @Length(2, 240)
  address?: string;

  // There is no identity field beyond `username` here, and requirement 17
  // forbids adding one. `forbidNonWhitelisted` on the global ValidationPipe
  // rejects any extra property, and a repo-wide grep gate backs it up.
}
