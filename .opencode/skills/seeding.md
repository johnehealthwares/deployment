# RxSoft Seeding

## Purpose

Add or modify seed data consistently across all RxSoft projects — idempotent upserts gated by `SEED_ON_START`.

## When to invoke

- When adding a new entity that needs reference data to function
- When creating development fixtures for testing
- When setting up a new development environment

## The Standard

All seeding should follow this pattern:

1. **Idempotent**: use `upsert()` by a unique key (code, name, or UUID)
2. **Gated**: controlled by `SEED_ON_START` env var (default: `false` for safety)
3. **Triggered from `src/database/seeding.service.ts`** with `OnModuleInit` or explicit call in `main.ts`
4. **Has a CLI command** for manual invocation (`npm run seed`)
5. **Logs what it does**: seed counts, skipped items, errors

## 6 different patterns across projects — use the right one

### conversation-engine
- **Pattern**: `model.replaceOne({ code }, data, { upsert: true })`
- **Trigger**: `npm run seed:questionnaires` (no auto-start); `SEED_ON_STARTUP` env var
- **Data source**: Google Sheets → CSV → JSON → hardcoded arrays
- **When adding**: Follow `seed-questionnaires.ts` pattern

### healthcare-concepts
- **Pattern**: `repository.findOne({ code })` → update or create
- **Trigger**: `SEED_ON_START=true` via `onApplicationBootstrap`; CLI: `seed:all`
- **Orchestrator**: `SeedOrchestratorService` runs facility → LOINC → ICD → drugs
- **When adding**: Create seeder in `src/modules/{module}/seeders/`, add CLI command in `seed.command.ts`, register in orchestrator

### rxsoft-backend
- **Pattern**: Raw SQL `ON CONFLICT DO UPDATE` or TypeORM `findOne` + create
- **Trigger**: `npm run seed` (broken — `run.ts` missing); `db:reset-and-seed` (drop+recreate)
- **Data source**: Google Sheets (items, prices) + hardcoded arrays
- **When adding**: Use `upsertBy()` pattern from seeds, add to seed order, ensure run.ts is fixed
- **⚠️ `generic-drugs copy.ts` (48K lines) is duplicated from healthcare-concepts — remove it and delegate**

### rxsoft-lis-backend
- **Pattern**: Custom `upsertBy(repo, key, payload)` helper
- **Trigger**: `SEED_ON_START=true` (default: false); CLI: `npm run seed`
- **When adding**: Add data to `seed-lis.ts`, use `upsertBy()`, add to `src/database/seeds/seed-lis.ts`

### rxsoft-identity
- **Pattern**: `findOne({ where: { code } })` → create if not exists
- **Trigger**: `SEED_ON_START=true` (default: true)
- **⚠️ Seeds on every start** — set default to `false` for production
- **When adding**: Add to `seed-identity.ts`

### healthcare-interoperability-switch
- **Pattern**: `repo.create()` + `repo.save()` — **NOT idempotent**
- **Trigger**: `OnModuleInit` (always, no env var)
- **⚠️ Duplicates on every restart** — needs `SEED_ON_START` gate and upsert logic
- **When adding**: Fix the service first, then add data to `seeder.service.ts`

## Refactoring consistency

1. **Add `SEED_ON_START` env var** to `healthcare-interoperability-switch` (currently seeds unconditionally)
2. **Fix idempotency** in `healthcare-interoperability-switch` — use upsert instead of create+save
3. **Set default to `false`** in `rxsoft-identity` — currently defaults to `true`
4. **Fix `rxsoft-backend` run.ts** — currently `run.tso` with broken import
5. **Remove duplicated drug data** in `rxsoft-backend` (48K-line copy of healthcare-concepts data)