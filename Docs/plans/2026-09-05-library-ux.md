# Library UX implementation

Implement the approved previews on `codex/library-ux` in an isolated worktree.

## Accepted design

- Preserve the main toolbar's Search, Add Reference, More import options, and Details actions.
- Move the existing property manager into the table toolbar and rename its entry point Manage Columns; preserve all property operations.
- Group Filter / Sort / Group on the left, Layout / Manage Columns on the right. Show current sort/group and removable active filters.
- Layout contains Comfortable / Compact density and existing per-column wrapping. Comfortable shows smaller author/year below each title with a two-line title by default.
- Search offers Everything / Papers / Notes & highlights with real matching behavior, preserving current filters and reference navigation.
- Assistant settings lead with provider connection and everyday choices. Keep permissions visible; place paths, prompts, storage, and diagnostics in Advanced.

## Implementation sequence

1. Inspect table, view persistence, search, and Assistant settings; preserve the existing data and preference contracts.
2. Implement library toolbar and row layout, including regression coverage for persistence and cell invalidation.
3. Implement search scopes with matching coverage and any required CLI parity.
4. Reorganize Assistant settings without changing permission defaults or provider configuration.
5. Build and run relevant tests; inspect the running worktree app using a separate test library.
6. Obtain independent codex-rescue review and parallel reuse/quality/efficiency reviews, address actionable findings, and revalidate.
7. Commit coherent changes on this branch. Do not merge, release, or modify the installed app.

## Verification

- Preserve macOS 14.4 compatibility and pinned dependencies.
- Cover search scope boundaries, annotations, escaping, existing type/year/PDF filters, and selected-library scope.
- Cover title-cell equality for author/year/density changes and preference defaults.
- Exercise toolbar popovers, Comfortable/Compact, wrapping, property manager, search navigation, and Assistant provider switching.
- Record actual validation results and material limitations below when complete.

## Implementation and validation

- Implemented the two toolbar groups, existing Manage Columns operations, Comfortable/Compact density, author/year bylines, and density-based title wrapping. The untouched seeded default view initializes its wrapping once; saved wrapping choices remain intact.
- Added real metadata/notes/annotation scopes and matching excerpts. Existing callers retain legacy FTS behavior unless they opt into a scope. CLI parity is available through `search --scope everything|papers|notes` without changing the JSON array contract.
- Reorganized Assistant settings into Connection, conversation defaults, visible Permissions, and expandable Advanced settings.
- Built successfully on the macOS host. `Package.resolved` is unchanged.
- Final regression run: 156 tests passed, 0 failures. Command:

  ```sh
  swift test --disable-automatic-resolution --filter 'ReferenceSearchScopeTests|LibraryUXTests|ReferenceTableCellEqualityTests|SearchQueryTests|PdfCommandTests|AppDatabaseTests|RubienPreferencesTests|FilterEngineTests|GroupEngineTests|AssistantModelOptionsTests|LibraryViewModelTests'
  ```

- Independent codex-rescue review and the reuse/quality/efficiency reviews completed. Fixed title-only substring matching, Unicode annotation matching, shared query normalization, unnecessary/canceled excerpt work, and stable seeded-view wrapping. A follow-up review found no further material issues.
- `git diff --check` passed. Linux CI and the entire test suite were not run locally; changed Mac-only sources/tests are guarded.
- Native visual verification is pending: the worktree app launched against `/private/tmp/rubien-library-ux-fixture` with sync disabled, but computer-use inspection was blocked because the Mac was locked. No installed-app or production-library changes were made for this verification.
