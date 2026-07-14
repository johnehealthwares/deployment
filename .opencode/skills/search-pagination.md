# RxSoft Search, Pagination & List Endpoints

## Purpose

Implement or refactor list/search endpoints to follow the `BACKEND_SEARCH_ARCHITECTURE.md` standard across all NestJS projects.

## When to invoke

- When adding a new list endpoint (`GET /resource`)
- When modifying an existing list endpoint
- When refactoring a module that returns unfiltered/unpaginated data

## The Standard

Every list endpoint should use:

1. **ListQueryDto** — shared DTO with `page`, `limit` (max 100), `search?`, `sortBy?`, `sortOrder?`, `offset()` getter
2. **Envelope**: `{ data: T[], meta: { page, limit, total } }`
3. **Free-text search**: ILIKE (PostgreSQL) or `$regex` (MongoDB) on relevant columns
4. **Filter engine**: `field=TYPE|value|valueTo` DSL for column-level filters
5. **Sort column allow-list**: validate `sortBy` against known columns (`@IsIn()`) to prevent injection
6. **Tenant scoping**: apply `organizationId` filter from JWT
7. **Soft-delete**: exclude `deleted_at IS NOT NULL` automatically

## Per-project deviations (fix when touching)

### conversation-engine (MongoDB)
- **No pagination** on channels endpoint — add `.skip().limit()`
- **No sort support** — all endpoints hardcode `{ createdAt: -1 }`
- **No tenant scoping** — schemas lack `organizationId`
- **FilterConversationInboxDto** is a plain class without decorators
- **Fix**: Add `sortBy`/`sortOrder` to `PaginatedQueryDto`, add tenant fields, fix Channel controller

### healthcare-concepts
- **No shared ListQueryDto** — each module reinvents it
- **Concepts controller** uses `Record<string, any>` — replace with validated DTO
- **`listValues` bug**: uses `page` as fallback for `limit`
- **`meta` === `pagination`**: same object reference (duplicate in response)
- **Sort not exposed** on most endpoints
- **Fix**: Create shared `ListQueryDto`, fix the bug, add sort expose, deduplicate meta

### healthcare-interoperability-switch
- **Pagination only in AE module** — all others return everything
- **No shared ListQueryDto**
- **No sort control** from API consumers
- **meta/pagination duplicate** bug
- **Fix**: Spread `executeListQuery` to all modules, add sort, fix bug

### rxsoft-backend
- **Two competing DTOs**: `ListQueryDto` and `PaginationQueryDto` — consolidate to one
- **`ListQueryDto.sortBy` has no `@IsIn()`** — potential SQL injection
- **Entity-specific DTOs don't extend ListQueryDto** — they standalone copy fields
- **Max limit 1,000,000** — essentially unlimited, set to 100
- **Fix**: Consolidate DTOs, add `@IsIn()` for sort, extend ListQueryDto everywhere

### rxsoft-lis-backend (BEST — closest to standard)
- **No filter DSL support** — only `search` param
- **`sortColumn()` has no allow-list** — any column name accepted
- **Extra `rawQuery: Record<string, string>`** captured but not applied as filters
- **Fix**: Add filter DSL, add sort column allow-list

### rxsoft-identity (WORST — largely unimplemented)
- **No ListQueryDto exists**
- **Users**: `search` param declared but NOT passed to use case
- **Roles**: pagination declared but returns all roles
- **Organizations/Locations**: stubs returning `{ data: [] }`
- **Roles returns raw array** instead of `{ data, meta }` envelope
- **Fix**: Create ListQueryDto, wire search through to repository, implement actual queries, fix envelope

## Workflow

1. Load project-specific `backend-list-endpoint` skill for exact file paths
2. Ensure `ListQueryDto` exists in `src/shared/dto/list-query.dto.ts` (copy from `BACKEND_SEARCH_ARCHITECTURE.md`)
3. Add sort column allow-list: `@IsIn(['name', 'code', 'createdAt', 'updatedAt'])`
4. Apply tenant scoping via `organizationId` from `@CurrentUser()`
5. Apply soft-delete filter where entities support it
6. Return `{ data, meta: { page, limit, total } }`