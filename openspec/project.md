# ZDBC OpenSpec Project

## Purpose

ZDBC is a column-oriented embedded database with a Zig core and Python bindings. Performance changes must preserve the fixed-width on-disk format and the existing public read APIs unless a change explicitly introduces an opt-in API.

## Change Conventions

- Put proposed work under `openspec/changes/<change-id>/`.
- Define observable behavior in a capability delta under `specs/`.
- Record benchmark baselines before changing an I/O path.
- Treat benchmark targets as gates, not as guaranteed outcomes.
- Keep on-disk compatibility and data-integrity checks mandatory.
