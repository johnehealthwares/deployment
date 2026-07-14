# RxSoft Schema & Migrations

## Purpose

Manage TypeORM schema changes across RxSoft projects — use proper migrations instead of `synchronize: true` in production.

## When to invoke

- When adding or modifying TypeORM entity fields
- When setting up a new project for production deployment
- When switching from `synchronize: true` to `synchronize: false` with migrations

## Current state per project

| Project | synchronize | Has migrations? | Risk |
|---|---|---|---|
| `rxsoft-backend` | `true` (default) | No | OK in dev; prod needs migrations |
| `rxsoft-identity` | `true` (default) | No | OK in dev; `DB_DROP_SCHEMA=true` is dangerous |
| `rxsoft-lis-backend` | `false` (default) | No | Safe — manual SQL scripts used |
| `healthcare-concepts` | `true` | No | **High risk** — no schema control at all |
| `healthcare-interoperability-switch` | `true` (dev) / `false` (prod) | No | Moderate risk |

## Workflow for adding migrations

1. Set `synchronize: false` in app.module.ts TypeORM config
2. Generate migration: `npx typeorm migration:generate src/database/migrations/{Name} -d src/database/data-source.ts`
3. Review the generated SQL carefully
4. Create the migration file in `src/database/migrations/`
5. Run migration to verify
6. Commit migration file

## Refactoring consistency

- **rxsoft-backend** has `schema_v2_pharmacy.sql` as a reference schema but no migration files
- **healthcare-concepts** uses `DB_DROP_SCHEMA=true` — data loss risk
- **rxsoft-identity** also uses `DB_DROP_SCHEMA=true` in `.env` — remove for anything beyond dev
- **rxsoft-lis-backend** has `DB_SYNCHRONIZE=false` — already production-safe, just needs migration files added
- **healthcare-interoperability-switch** switches based on `NODE_ENV` — correct pattern, needs migration files