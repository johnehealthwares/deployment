# RxSoft Google Sheets Import & Seeding

## Purpose

Add or modify Google Sheets import/seeding across RxSoft projects — standardized service account auth, content hash tracking, and sync status write-back.

## When to invoke

When adding a new Google Sheets data source for seeding (LOINC, ICD, questionnaires, items, facilities, etc.).

## When not to invoke

For code-only seeding or single-file CSV imports.

## The Mature Pattern (from healthcare-concepts & rxsoft-backend)

The three projects that use Google Sheets (conversation-engine, healthcare-concepts, rxsoft-backend) follow similar but not identical patterns. The **healthcare-concepts** pattern is the most mature and should be the template.

## The Standard (healthcare-concepts pattern)

1. **Auth**: `google-auth-library` SDK with `GoogleAuth` using `GOOGLE_CLIENT_EMAIL` / `GOOGLE_PRIVATE_KEY` env vars
2. **Read**: Google Sheets API v4 `spreadsheets.values.get` with `majorDimension: 'ROWS'`
3. **Column mapping**: Row header → named fields, with `columnNameMap` for normalization
4. **Content hash**: Generate SHA-256 hash of sheet content for change detection
5. **Tracking**: `ImportTrackingEntity` records revision, rows added/modified/deleted, status per run
6. **Write-back**: Write UUID, sync_status, sync_message, sync_time back to sheet for audit trail
7. **Fallback**: Try Google Sheets first; if env vars missing, fall back to local CSV/JSON

## Per-project variations

### conversation-engine
- **Auth**: Self-contained JWT Bearer assertion (RS256 via `node:crypto` `createSign`) — no SDK dependency
- **SDK**: Manual HTTP, no `google-auth-library`
- **Use case**: Questionnaire seeding only
- **Fallback chain**: Google Sheets → CSV → JSON → hardcoded arrays
- **Key file**: `src/scripts/questionnaire-seed-loader.ts`
- **Refactoring**: Consider migrating to `google-auth-library` SDK for consistency

### healthcare-concepts (THE TEMPLATE)
- **Auth**: `google-auth-library` SDK, two instances (readonly + read/write for facility sync)
- **Use cases**: LOINC, ICD-10, Facility registry
- **Key files**: `src/common/services/google-sheets.service.ts`, `facility-sheets.service.ts`
- **Best practice**: Content hash tracking, ImportTrackingEntity, sync status write-back

### rxsoft-backend
- **Auth**: `GoogleSheetReaderService` + `GoogleSheetStatusWriter`
- **Use cases**: Item templates, price list import
- **⚠️ Security**: Hardcoded fallback private key in code — remove
- **Key files**: `src/database/import/`, `src/database/seeds/4-seed-item-template.ts`

## Workflow

1. Create seeder service in `src/modules/{module}/seeders/`
2. Use Google Sheets API v4 with service account credentials
3. Read data, create content hash, compare with last import
4. Upsert entities with change tracking
5. Write sync status back to spreadsheet
6. Register in the project's seed orchestrator
7. Add env vars for sheet ID and credentials

## Refactoring consistency

- **Rxsoft-backend**: Remove hardcoded fallback private key from seed scripts — only use env vars
- **Conversation-engine**: Consider migrating to `google-auth-library` SDK instead of manual JWT signing
- **All projects**: Use `ImportTrackingEntity` pattern from healthcare-concepts for audit trail
- **All projects**: Write sync status back to sheet (healthcare-concepts pattern with UUID, status, message, time columns)