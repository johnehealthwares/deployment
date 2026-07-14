# RxSoft Ecosystem

## What this is

RxSoft is a multi-project healthcare software suite. This skill is the parent for all RxSoft work — it runs **before** any project-specific skill to establish context.

## Before searching raw files — try Graphify first

This repo has a knowledge graph at `graphify-out/` with 17,256 nodes, 43,175 edges, and 631 communities. Before grepping or reading many files, run:

- `graphify query "<question>"` — architecture, dependencies, symbol relationships
- `graphify path "<A>" "<B>"` — relationships between entities
- `graphify explain "<concept>"` — explain a concept with its neighbors

These return a scoped subgraph (usually <50 nodes), much faster than raw file searches.

## Projects at a glance

| Directory | Stack | Port | Purpose |
|---|---|---|---|
| `conversation-engine/` | NestJS + Mongoose | 8090 | Questionnaire-driven conversations |
| `healthcare-concepts/` | NestJS + TypeORM | 3011 | LOINC/ICD/facility coding concepts |
| `healthcare-interoperability-switch/` | NestJS + TypeORM | 3000 | Healthcare message routing/switching |
| `rxsoft-admin-3/` | React + Mantine + Vite | 5173 | Admin frontend (pharmacy, LIS, etc.) |
| `rxsoft-backend/` | NestJS + TypeORM | 8080 | Pharmacy management backend |
| `rxsoft-lis-backend/` | NestJS + TypeORM | 8091 | Laboratory information system |
| `rxsoft-identity/` | NestJS + TypeORM | 8092 | Auth, users, roles, permissions |
| `rxsoft-mobile/` | Kotlin + Jetpack Compose | — | Native Android app |

## Universal conventions

- **Kebab-case** for filenames, **PascalCase** for classes, **camelCase** for variables
- **E2E tests**: `*.e2e-spec.ts`. **Unit tests**: `*.spec.ts`. Co-located with source.
- Every backend seeds on startup via `SEED_ON_START` env var; seeding is idempotent (upsert)
- JWT auth with shared `JWT_ACCESS_SECRET` across all services, token payload includes `sub`, `organizationId`, `locationId`, `username`, `roles`, `permissions`
- `@CurrentUser()` decorator extracts user from JWT on protected endpoints
- DTOs use `class-validator` + `class-transformer` in NestJS projects
- All NestJS backends use `emitDecoratorMetadata` + `experimentalDecorators`

## When to use

**Always** when working on any RxSoft project. This skill establishes context; delegate to project-specific skills for implementation details.

## When not to use

When the task is unrelated to this repository.

## Refactoring consistency goals

Every change should move the codebase toward consistency across these dimensions:

### List endpoints (BACKEND_SEARCH_ARCHITECTURE.md)
| Deviation | conversation-engine | healthcare-concepts | healthcare-interop-switch | rxsoft-backend | rxsoft-lis-backend | rxsoft-identity |
|---|---|---|---|---|---|---|
| Shared ListQueryDto | `PaginatedQueryDto` | **None** — each module reinvents | **None** | **Two** — `ListQueryDto` + `PaginationQueryDto` | `ListQueryDto` | **None** |
| Sort support | **None** — hardcoded `{createdAt:-1}` | GenericProducts only | **None** | Some modules, **injection risk** | sortBy/sortOrder, **no allow-list** | **None** |
| Search | MongoDB `$regex 'i'` | `LIKE` / DSL | DSL only (AE module) | ILIKE (PG) | ILIKE | **Declared but not wired** |
| Response envelope | `{data,meta}` most; raw array for Channel | `{data,pagination,meta}` **dup bug** | `{data,pagination,meta}` **dup bug** | `{data,meta}` consistent | `{data,meta}` consistent | `{data,meta}` Users / **raw array** Roles |
| Tenant scoping | **None** — schemas lack orgId | **None** | **None** | Yes (orgId) | Yes (orgId + locId) | Yes (orgId) |
| Soft delete | **None** — hard deletes | GenericProducts only | softDelete() used | Inconsistent | **All queries** | None observed |
| Pagination completeness | **Channel: none** | **Filter engine**: Concepts only | **AE only** — rest return all | **Consistent** | **Consistent** | **Roles: none**, Orgs: stub |
| Sort allow-list | N/A | No | N/A | **Items only** | **No** | N/A |

### Auth
| Deviation | conv-engine | hc-concepts | hc-interop | rxsoft-backend | rxsoft-lis | rxsoft-identity |
|---|---|---|---|---|---|---|
| JWT guard on HTTP | **None** | **None** | **None** | Global | Global | Global |
| `@Public()` support | N/A | N/A | N/A | Yes | Yes | Yes |
| `x-api-key` support | N/A | N/A | N/A | Yes | Yes (interop) | Yes |
| Permissions guard | N/A | N/A | N/A | Yes | Exists, not global | Exists, **unused** |
| Password hashing | N/A | N/A | N/A | N/A | N/A | **SHA-256 (no salt)** |

### Tests
| Metric | conv-engine | hc-concepts | hc-interop | rxsoft-backend | rxsoft-lis | rxsoft-identity | rxsoft-admin-3 | rxsoft-mobile |
|---|---|---|---|---|---|---|---|---|
| Test files | 19 | **0** | 4 | 31 | 1 | **0** | 1 | **0** |
| Unit tests | 8 | 0 | 3 | 23 | 0 | 0 | 1 | 0 |
| Integration tests | 1 | 0 | 0 | 7 | 1 | 0 | 0 | 0 |
| E2E tests | 12 | 0 | 1 | 1 | 0 | 0 | 0 | 0 |
| Has CI workflow | No | No | No | No | No | No | Yes | No |
| Test DB strategy | MongoMemoryServer | N/A | SQLite | SQL.js in-memory | Real PostgreSQL | N/A | jsdom | N/A |

### Seeding
| Deviation | conv-engine | hc-concepts | hc-interop | rxsoft-backend | rxsoft-lis | rxsoft-identity |
|---|---|---|---|---|---|---|
| Idempotent | Yes (upsert) | Yes (find+update) | **No** (create+save) | **Mixed** | Yes (upsertBy) | Yes (find+create) |
| SEED_ON_START gate | Yes | Yes | **No** — seeds always | **Stub** (no-op) | Yes (default: false) | Yes (default: true) |
| Google Sheets | Yes | Yes | No | Yes | No | No |
| Orchestrator | No (independent scripts) | SeedOrchestratorService | Single service | **Broken** (run.ts missing) | Single function | Single function |

### Schema / Migrations
| Project | synchronize | DB_DROP_SCHEMA | Migrations | Risk |
|---|---|---|---|---|
| rxsoft-backend | true (default) | false | None | Low (dev only) |
| rxsoft-identity | true (default) | **true** | None | **High** — data loss risk |
| rxsoft-lis-backend | false (default) | false | None | Low |
| healthcare-concepts | true | **true** | None | **High** — no schema control |
| healthcare-interoperability-switch | true (dev) | false | None | Moderate |

## Targets

1. **List endpoints**: match `BACKEND_SEARCH_ARCHITECTURE.md` standard in all projects
2. **Auth**: consistent JWT with shared secret, `@Public()`, `@CurrentUser()`, `x-api-key` for service-to-service
3. **Seeding**: idempotent upserts gated by `SEED_ON_START`, SEED_ON_START defaults to false
4. **DTOs**: `class-validator` with `@Type()` decorators everywhere, never `Record<string, any>`
5. **Tests**: every project has at least integration tests; projects with zero tests (rxsoft-identity, healthcare-concepts) prioritized
6. **TypeORM**: migrations, not `synchronize: true` in production-like environments; no `DB_DROP_SCHEMA` outside dev
7. **Password hashing**: bcrypt/argon2, not plain SHA-256
8. **Duplicate data**: remove `generic-drugs copy.ts` from rxsoft-backend (duplicate of healthcare-concepts)
9. **Google Sheets**: use `google-auth-library` SDK (not manual JWT), no hardcoded private keys in code
10. **Dual database**: use `createRepositorySwitchProviders()` factory when adding in-memory repository switching