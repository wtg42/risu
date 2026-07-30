# Risu Agent Guidelines

## Project goal

Risu provides beautiful, lightweight, and composable interactive CLI prompts
implemented natively in Zig.

Risu is inspired by [Clack](https://github.com/bombshell-dev/clack). Its UX,
prompt lifecycle, and `core` / `prompts` layering are useful design references.

## Upstream reference

`/home/weiting/clack` is a read-only upstream reference. Do not include it in
the Risu repository, modify it, or commit changes to it.

Clack is not a runtime dependency. If Clack code is ever substantially copied
or adapted, preserve its [MIT license notice](https://github.com/bombshell-dev/clack/blob/main/packages/core/LICENSE).

## Implementation principles

- Do not translate the TypeScript implementation line by line.
- Prefer idiomatic Zig with explicit ownership, allocators, error sets, and
  injectable I/O.
- The first phase is project scaffolding only. Do not predetermine or implement
  the prompt API.
