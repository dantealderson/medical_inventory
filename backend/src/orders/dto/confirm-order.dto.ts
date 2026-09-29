import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { IsArray, IsInt, IsOptional, IsUUID, Min, ValidateNested } from 'class-validator';

export class LineEditDto {
  @ApiProperty()
  @IsUUID()
  orderLineId!: string;

  @ApiProperty({
    description:
      'Approved quantity in whole boxes, 0..requested. 0 drops the line. The upper bound is checked by the service, which knows the request.',
  })
  @IsInt()
  @Min(0)
  qtyBoxes!: number;
}

export class ConfirmOrderDto {
  @ApiPropertyOptional({
    type: [LineEditDto],
    description: 'Only the lines being reduced. Omitted lines are approved as requested.',
  })
  @IsOptional()
  @IsArray()
  @ValidateNested({ each: true })
  // Without @Type the elements stay plain objects. class-validator then
  // skips their rules, and the whitelist cannot reject their extra keys.
  @Type(() => LineEditDto)
  lines?: LineEditDto[];
}
