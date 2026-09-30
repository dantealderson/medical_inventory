import { ApiPropertyOptional } from '@nestjs/swagger';
import { IsBoolean, IsInt, IsOptional, IsString, Matches, Max, Min } from 'class-validator';

/**
 * The admin's controls over one item on one clinic's shelf (requirement 4).
 * A key left out is unchanged; `null` clears the rate or the minimum.
 * @IsOptional lets null through, which is exactly what "clear" needs.
 */
export class UpdateClientInventoryDto {
  @ApiPropertyOptional()
  @IsOptional()
  @IsBoolean()
  autoDecrementEnabled?: boolean;

  @ApiPropertyOptional({
    nullable: true,
    description: 'Units per day as a decimal string, at most 4 decimals; null clears it',
    example: '2.5',
  })
  @IsOptional()
  @IsString()
  @Matches(/^\d{1,6}(\.\d{1,4})?$/)
  usageRateOverride?: string | null;

  @ApiPropertyOptional({ nullable: true, minimum: 0, maximum: 99_999, description: 'Whole boxes; null clears it' })
  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(99_999)
  minQtyBoxes?: number | null;
}
