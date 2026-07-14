# RxSoft Testing

## Purpose

Add tests (unit, integration, or e2e) to any RxSoft project following the conventions of that project.

## When to invoke

- When adding a new module/resource — add tests alongside it
- When fixing a bug — add a test that reproduces the issue
- When touching a project with zero test coverage (`rxsoft-identity`, `healthcare-concepts`)

## When not to invoke

- For deployment config changes
- For documentation-only changes

## Project-specific conventions

### conversation-engine (Jest, Mongoose)
- **Unit**: `*.spec.ts` co-located or in `test/modules/`. Pure mocks, no DB.
- **Integration**: `*.e2e-spec.ts` in `test/modules/`. Uses `MongoMemoryReplSet` (replica set required for change streams). Helper: `src/test-utils/test-db.ts`.
- **Config**: `test/jest-e2e.json` for e2e/integration. Inline in `package.json` for unit.
- Use `createTestingModule()` from `src/test-utils/test-db.ts`.

### rxsoft-backend (Jest, TypeORM)
- **Unit**: `*.spec.ts` in `src/modules/{module}/services/__tests__/` or `src/modules/{module}/controllers/__tests__/`. Jest mocks, no DB.
- **Integration**: `*.integration.spec.ts` in `src/integration/`. Use `sqljs` in-memory DB via `sqlite-test-helpers.ts`. Seeds base data and provides JWT tokens.
- **Config**: Inline in `package.json`. E2E at `test/jest-e2e.json`.
- **Guard**: `describeIfDbReady` for skipping when SQL.js not available.

### rxsoft-lis-backend (Jest, TypeORM)
- **Integration only**: `*.integration.spec.ts` co-located in `src/`. Uses real PostgreSQL (`SKIP_AUTH=true`).
- **Config**: `jest.integration.config.ts` with `--runInBand`.
- **Missing**: No unit tests currently.

### healthcare-interoperability-switch (Jest, SQLite)
- **Unit**: `*.spec.ts` in `src/modules/{module}/`. Pure mocks.
- **E2E**: `*.e2e.spec.ts` in `src/`. Uses SQLite via `process.env.DB_TYPE='sqlite'` + `MockReceiverService`.
- **Config**: Inline in `package.json`.

### rxsoft-admin-3 (Vitest, jsdom)
- **Unit**: `*.test.tsx` co-located in `src/`. Uses `@testing-library/react` + custom render in `test-utils/`.
- **Setup**: `vitest.setup.mjs` mocks `window.matchMedia`, `ResizeObserver`.
- **Config**: In `vite.config.mjs` (test section).

### rxsoft-identity — NO TESTS EXIST
- **Needs**: Full test suite. Start with integration tests using SQLite (set `DB_TYPE=sqlite`). Copy pattern from `rxsoft-backend/src/integration/support/sqlite-test-helpers.ts`.
- **Priority**: Unit tests for use cases (LoginUseCase, CreateUserUseCase, etc.).

### healthcare-concepts — NO TESTS EXIST
- **Needs**: Full test suite. Start with integration tests using SQLite (default DB). Copy pattern from `rxsoft-lis-backend` using `DB_TYPE=sqlite` + supertest.

## Workflow

1. Check which project you're in — read this skill's per-project conventions
2. Follow that project's naming convention, test DB strategy, and directory structure
3. For unit tests: mock dependencies, test edge cases, test error paths
4. For integration tests: boot NestJS with `Test.createTestingModule`, configure test DB, seed baseline data, use supertest for HTTP
5. Verify tests pass before committing

## Refactoring consistency

- **Projects with zero tests**: `rxsoft-identity` and `healthcare-concepts` need the most attention
- **rxsoft-lis-backend**: Needs unit tests alongside the single integration test
- **rxsoft-admin-3**: Only 1 test file exists despite full test infrastructure
- **rxsoft-mobile**: Test dependencies declared but no tests written