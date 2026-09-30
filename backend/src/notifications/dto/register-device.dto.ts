import { ApiProperty } from '@nestjs/swagger';
import { IsIn, IsString, MaxLength, MinLength } from 'class-validator';

export class RegisterDeviceDto {
  @ApiProperty({ description: 'The FCM registration token' })
  @IsString()
  @MinLength(1)
  @MaxLength(4096)
  fcmToken!: string;

  @ApiProperty({ enum: ['android', 'ios', 'web'] })
  @IsIn(['android', 'ios', 'web'])
  platform!: 'android' | 'ios' | 'web';
}
