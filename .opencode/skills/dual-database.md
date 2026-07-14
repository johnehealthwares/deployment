# RxSoft Dual Database & In-Memory Repository

## Purpose

Work with rxsoft-backend's dual-database architecture — PostgreSQL (TypeORM) + In-Memory (`USE_IN_MEMORY_REPOS=true`) + MongoDB (Mongoose for APM).

## When to invoke

When modifying repository implementations, adding new repositories, or working with in-memory/type-switching modules in rxsoft-backend.

## Architecture

Three database modes co-exist:

```
DB_TYPE:             postgres            postgres +                sqljs
                     (prod/CI)           USE_IN_MEMORY=true        (test)
TypeORM:             PostgreSQL active   TypeORM imports SKIPPED   SQL.js in-memory
InMemory repos:      SKIPPED             Map-based repos active    SKIPPED
MongoDB (APM):       Active              Active                    Active (if on)
```

## The Interface + Two-Implementation Pattern

Each module that supports in-memory switching follows this pattern:

**1. Repository Interface** (`modules/{module}/repositories/{entity}.repository.ts`)
- Defines the contract (all methods)
- Also defines query types and return types

**2. TypeORM Implementation** (`.../typeorm-{entity}.repository.ts`)
- `@Injectable()` class implementing the interface
- Injects `@InjectRepository()` entities
- Uses `DataSource` for transactions
- Maps ORM entities to domain objects

**3. In-Memory Implementation** (`.../in-memory-{entity}.repository.ts`)
- `@Injectable()` class implementing the interface
- Uses `Map<string, DomainEntity>` internally
- Seeds basic data in constructor for testing
- Simple array operations instead of QueryBuilder

**4. DI Token** (`services/{module}.di-tokens.ts`)
- Exports `export const ENTITY_REPOSITORY = Symbol('ENTITY_REPOSITORY')`

**5. Module wiring** — the module conditionally imports TypeORM entities and wires the correct impl:
```typescript
const useInMemory = config.get('USE_IN_MEMORY_REPOS') === 'true';
const persistenceImports = useInMemory ? [] : [TypeOrmModule.forFeature([...])];
const repoProviders = useInMemory
  ? [InMemoryRepo, { provide: DI_TOKEN, useExisting: InMemoryRepo }]
  : [TypeormRepo, { provide: DI_TOKEN, useExisting: TypeormRepo }];
```

## Creating a new dual-database module

1. Create domain entity in `domains/` (plain TS class)
2. Create TypeORM entity in `entities/`
3. Create repository interface in `repositories/`
4. Create TypeORM implementation in `repositories/`
5. Create In-Memory implementation in `repositories/`
6. Create DI token in `services/`
7. Wire conditional imports in the module using `createRepositorySwitchProviders()` from `src/common/util.ts`

## Modules currently using this pattern

| Module | DI Token | TypeORM Impl | InMemory Impl |
|---|---|---|---|
| catalog | `ITEM_REPOSITORY` | `TypeormItemRepository` | `InMemoryItemRepository` |
| sales | `SALES_REPOSITORY` | `TypeormSalesRepository` | `InMemorySalesRepository` |
| inventory | `INVENTORY_REPOSITORY` | `TypeormInventoryRepository` | `InMemoryInventoryRepository` |
| purchases | `PURCHASES_REPOSITORY` | `TypeormPurchasesRepository` | `InMemoryPurchasesRepository` |
| receivables | `RECEIVABLES_REPOSITORY` | `TypeormReceivablesRepository` | `InMemoryReceivablesRepository` |
| audit | `AUDIT_LOG_REPOSITORY` | `TypeormAuditLogRepository` | `InMemoryAuditLogRepository` |

## Refactoring consistency

When adding a new module with dual-database support, always use `createRepositorySwitchProviders()` factory from `src/common/util.ts` rather than inline conditional wiring.