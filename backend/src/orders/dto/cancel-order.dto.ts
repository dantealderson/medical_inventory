import { ApiPropertyOptional } from '@nestjs/swagger';
import { CancelDisposition } from '@prisma/client';
import { IsEnum, IsOptional, IsString, Length } from 'class-validator';

/**
 * A clinic can only cancel its own PLACED order, where nothing was reserved,
 * so it has no disposition to give. The field does not exist here, and
 * forbidNonWhitelisted turns an attempt to send one into a 400.
 */
export class ClientCancelOrderDto {
  @ApiPropertyOptional({ minLength: 1, maxLength: 500 })
  @IsOptional()
  @IsString()
  @Length(1, 500)
  reason?: string;
}

export class AdminCancelOrderDto {
  @ApiPropertyOptional({
    enum: CancelDisposition,
    description:
      'Required at OUT_FOR_DELIVERY and refused at every other status, where the server records the disposition itself. RETURNED_TO_WAREHOUSE restores the batches. WRITTEN_OFF restores nothing and writes no movement.',
  })
  @IsOptional()
  @IsEnum(CancelDisposition)
  disposition?: CancelDisposition;

  @ApiPropertyOptional({ minLength: 1, maxLength: 500 })
  @IsOptional()
  @IsString()
  @Length(1, 500)
  reason?: string;
}
