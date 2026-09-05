# Library UX implementation

Implement the approved previews on `codex/library-ux` in an isolated worktree.

## Accepted design

- Preserve the main toolbar's Search, Add Reference, More import options, and Details actions.
- Move the existing property manager into the table toolbar and rename its entry point Manage Columns; preserve all property operations.
- Group Filter / Sort / Group on the left, Layout / Manage Columns on the right. Show current sort/group and removable active filters.
- Layout contains Comfortable / Compact density and existing per-column wrapping. Comfortable shows smaller author/year below each title with a two-line title by default.
- Search offers Everything / Papers / Notes & highlights with real matching behavior, preserving current filters and reference navigation.
- Assistant settings lead with provider connection and everyday choices. Keep the selected provider’s binary path in Connection and permissions visible; place workspace, prompts, storage, and diagnostics in Advanced.

## Implementation sequence

1. Inspect table, view persistence, search, and Assistant settings; preserve the existing data and preference contracts.
2. Implement library toolbar and row layout, including regression coverage for persistence and cell invalidation.
3. Implement search scopes with matching coverage and any required CLI parity.
4. Reorganize Assistant settings without changing permission defaults or provider configuration.
5. Build and run relevant tests; inspect the running worktree app using a separate test library.
6. Obtain independent codex-rescue review and parallel reuse/quality/efficiency reviews, address actionable findings, and revalidate.
7. Commit coherent changes on this branch. Following user acceptance, merge locally after final validation. Do not push, release, or modify the installed app.

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
- Initial regression run: 156 tests passed, 0 failures. Command:

  ```sh
  swift test --disable-automatic-resolution --filter 'ReferenceSearchScopeTests|LibraryUXTests|ReferenceTableCellEqualityTests|SearchQueryTests|PdfCommandTests|AppDatabaseTests|RubienPreferencesTests|FilterEngineTests|GroupEngineTests|AssistantModelOptionsTests|LibraryViewModelTests'
  ```

- Independent codex-rescue review and the reuse/quality/efficiency reviews completed. Fixed title-only substring matching, Unicode annotation matching, shared query normalization, unnecessary/canceled excerpt work, and stable seeded-view wrapping. A follow-up review found no further material issues.
- `git diff --check` passed. Linux CI and the entire test suite were not run locally; changed Mac-only sources/tests are guarded.
- Initial native inspection was blocked by a locked Mac. Subsequent checks used a temporary development preview bundle built from this worktree, against `/private/tmp/rubien-library-ux-fixture` with sync disabled. Confirmed Comfortable title/byline rendering, Manage Columns and custom property creation, Layout access, selected-row add controls and their pickers. Subsequent native checks confirmed both Assistant providers and their binary-path controls in Connection. The complete search interaction flow still requires a manual pass. No installed-app or production-library changes were made for this verification.

## Follow-up: contextual add-option controls

Show the existing + option and + tag affordances when their cell is hovered, their table row is selected, their picker is open, or the button has keyboard focus. Keep controls mounted to preserve keyboard/accessibility access and stable row geometry. Thread selection through the equatable table-cell dispatchers and cover selection invalidation before building and reviewing the change.

- Native preview confirmed both controls appear on selected rows and open their existing pickers; idle rows omit the controls. The UI automation API has no pointer-only hover action, so hover-only transitions were not directly exercised.
- Native inspection also exposed the Details overlay covering Layout and Manage Columns. Position the inspector below the measured table header so the toolbar stays accessible, including when controls or filters wrap.
- Verified the placement fix in the native preview: Details starts below the toolbar and Layout opens while Details remains visible.
- Build and 17 focused regression tests passed. Independent codex-rescue and reuse/quality/efficiency reviews found no actionable issues in the contextual controls or inspector correction.

## Follow-up: unselected row hover

The user confirmed that cell-level hover failed to reveal controls on unselected rows. Reuse the existing native table row-hover tracker to publish the hovered reference independently of selection, pass that state through the equatable cells, and retain cell hover, focus, and open-picker visibility. Resolve group headers and reordered rows through the same row identity map as selection scrolling. Cover unselected/selected rows, group headers, exit, and mapping changes in regression tests before rebuilding the preview.

- Build and 20 focused tests passed. The independent review identified stationary-pointer programmatic scrolling; added clip-view bounds observation and regression coverage for notification delivery and cleanup. Follow-up review and reuse/quality/efficiency reviews found no remaining actionable issues.
- Refreshed the sample preview. Direct pointer-only UI verification remains unavailable through the automation API; requested the user's hover check.

## Final acceptance and local integration

- Default columns are Title, Tags, custom columns, Status, Year, Authors, then other metadata. Existing saved column customization takes precedence.
- Manage Columns is 200 points wide, omits its redundant heading, and places creation on the left. Layout uses the same native popover presentation, with smaller density labels, subdued selection color, and hover feedback. Active filters align left with the toolbar controls.
- Both Assistant providers expose their binary-path override in Connection; Advanced retains the remaining runtime settings. Native checks covered provider switching, and the preview was restored to Claude.
- The user accepted the preview and authorized local integration. Final build passed and the combined regression run passed 166 tests with zero failures, including row-hover and picker-selection coverage. Pinned dependencies remain unchanged. Independent reviews and focused native checks are recorded above; full-suite and Linux CI validation were not performed locally.
