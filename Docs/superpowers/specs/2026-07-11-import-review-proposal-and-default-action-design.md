# Import Review Proposal Selection and Default Import Action

- **Date:** 2026-07-11
- **Status:** Approved design
- **Scope:** macOS import source and review sheets. CLI and MCP behavior remains unchanged.

## Goal

Remove a redundant confirmation step for usable, non-authoritative metadata and
make the initial Import sheet work naturally from the keyboard.

## Proposal selection

A review row with a usable proposed reference does not show **Use proposed
metadata**. Instead, it is directly selectable and starts unselected. Selecting
the row and pressing **Confirm N selected** is the user's explicit acceptance of
that proposal.

Other row behavior remains distinct:

- authoritative verified metadata is ready and selected by default;
- ambiguous metadata still requires **Choose match…** before selection; and
- results without a usable reference remain blocked and unselectable.

The behavior applies consistently to PDF, identifier, and durable pending-
metadata review contexts. No metadata editing UI is added to the import stage.

## Default Import action

The initial PDF/Markdown source sheet's **Import** button is the default action.
Return or Enter triggers it whether focus is in the path/URL field or has
returned from the multi-file picker.

The keyboard shortcut follows the button's existing state: it cannot submit an
empty or invalid source and does nothing while an import is already running.
Escape remains the cancel action. The review sheet retains its explicit selected
confirmation behavior.

## Verification

Tests cover:

- usable proposals being selectable but initially unselected;
- selected proposals committing without a separate promotion action;
- candidate and blocked rows retaining their existing behavior; and
- the source sheet Import button exposing the default-action keyboard shortcut
  while respecting disabled and busy states.

Manual smoke testing confirms Return imports a typed path/URL and a set of files
returned by **Choose…**.
