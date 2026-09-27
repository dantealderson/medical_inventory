import { Controller, Get, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';

import { SearchDto } from './dto/search.dto';
import { SearchService, type SearchResults } from './search.service';

@ApiTags('search')
@ApiBearerAuth()
@Controller('search')
export class SearchController {
  constructor(private readonly search: SearchService) {}

  @Get()
  run(@Query() query: SearchDto): Promise<SearchResults> {
    // The raw query goes straight through: normalisation happens in
    // PostgreSQL, by the same function that produced the stored form.
    return this.search.search(query.q, query.limit ?? 30);
  }
}
