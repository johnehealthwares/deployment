# RxSoft Data Table (Frontend)

## Purpose

Create data tables, forms, and pages in rxsoft-admin-3 using the dynamic `ModelConfig` system for consistency.

## When to invoke

When adding a new CRUD(generic with few customizations like actions) page or data-display component in the admin frontend.

## The Dynamic CRUD System

Located in `src/features/components/`:

- **`model-schema.ts`**: `ModelConfig` type — defines a complete CRUD resource:
  - `endpoint` — API path
  - `columns` — table column definitions (label, accessor, sortable, render)
  - `fields` — form field definitions (type, validation, group)
  - `fieldGroups` — groups for form layout
  - `tabGroups` — tab groupings for complex forms
  - `buildPayload` — transform form data → API payload
  - `apiProvider` — which API client to use

- **`data-page-shell.tsx`**: Full-page list view with:
  - `MetricsBar` for KPIs
  - `HeaderBar` for actions (create, refresh)
  - Paginated data table
  - Filter modal
  - Empty state

- **`data-page-form.tsx`**: Create/edit form with:
  - Dynamic field rendering via `RenderField`
  - Field groups and tab groups
  - Validation via React Hook Form + Zod
  - Mutation handling

- **`paginated-data-table.tsx`**: Table component with:
  - Server-side pagination, sorting, filtering
  - Action cells (edit, delete, view)
  - Selection support
  - CSV export

- **`form/`**: Form engine:
  - `form-provider.tsx`
  - `RenderField.tsx` — renders fields by type (text, select, date, async, remote select)
  - `field-group-engine.tsx` — layout engine for field groups
  - `FieldGroup.tsx` — labeled field group component
  - `tab-groups.tsx` — tabbed form sections
  - `ModalDataForm.tsx` — modal form wrapper

## When to use `ModelConfig` vs custom page

**Use `ModelConfig`** for: Simple CRUD (create, read, update, delete, list). Add config to module's `src/features/{module}/registry/index.ts`.

**Use custom page** for: Complex dashboards, reports, multi-step workflows, or UIs that don't fit the CRUD pattern.

## Workflow

1. Determine if the resource fits the `ModelConfig` pattern
2. If yes: add config to the module's registry, create route file in `src/routes/`
3. If custom: create page component, use `paginated-data-table.tsx` for data display, `ModalDataForm` for forms
4. Use the module's API client (`rxsoftApi`, `lisApi`, `conversationApi`, etc.)
5. Use TanStack Query for data fetching
6. Handle errors via `handleServerError()`

## Refactoring

Prefer `ModelConfig` over bespoke components when possible. This reduces code duplication and ensures all CRUD pages have the same UX.