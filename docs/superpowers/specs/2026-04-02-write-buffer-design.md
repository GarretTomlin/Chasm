# Write Buffer — Named Output Sections Design

**Date:** 2026-04-02  
**Status:** Approved

## Problem

The Chasm bootstrap codegen currently calls `print()` directly to stdout from every emit function. This makes multi-section output impossible: you cannot write to section B while emitting section A and have B appear before A in the final output. The goal is to enable writing to any named output section from anywhere in the codegen pass, with sections flushed in a fixed order at the end.

## Constraint

Chasm arrays are pass-by-value at the struct level. `.push()` mutations on an array field inside a struct do not propagate back to the caller. Only `.set()` on heap-allocated data propagates, because all copies of a `[]T` field share the same underlying data pointer. The solution must use pre-allocation + `.set()` (the same pattern as `DiagCollector`).

## Design

### New types and constants (`helpers.chasm`)

```
# Section IDs — output is flushed in this order
@SEC_PRE   = 0   # preamble: includes, header comment
@SEC_TYPES = 1   # enum and struct typedefs
@SEC_HELP  = 2   # typed array helpers (per-struct and @attr fixed)
@SEC_FWD   = 3   # function forward declarations
@SEC_BODY  = 4   # function bodies

defstruct SectionBuf do
  lines  :: []string   # pre-allocated to 4096 slots
  cursor :: []int      # singleton [0] tracking write position
end
```

`SectionBuf` is initialised by pre-allocating `lines` to 4096 empty strings and setting `cursor` to `[0]`. Because `lines` and `cursor` are heap-allocated arrays, copying a `SectionBuf` by value preserves the underlying data pointer — `.set()` calls on the copy mutate the shared heap data and are visible to all callers.

### CCtx change (`helpers.chasm`)

```
defstruct CCtx do
  pool     :: []Node
  ch       :: []int
  types    :: []int
  structs  :: []StructDef
  fns      :: []FnSig
  fields   :: []FieldDef
  sections :: []SectionBuf   # 5 pre-allocated slots, one per section
end
```

`make_cctx` builds 5 `SectionBuf` values and pushes them into a `[]SectionBuf` before constructing `CCtx`.

### Emit helper (`helpers.chasm`)

```
defp sec_emit(cctx :: CCtx, sec_id :: int, line :: string) do
  sb = cctx.sections.get(sec_id)
  n  = sb.cursor.get(0)
  if n < 4096 do
    sb.lines.set(n, line)
    sb.cursor.set(0, n + 1)
  end
end
```

The capacity guard mirrors `DiagCollector`'s 256-cap guard. 4096 lines per section is conservative; bump the constant if needed.

### Flush (`emit.chasm`)

Added as `flush_sections(cctx)`, called at the end of `codegen()`:

```
defp flush_sections(cctx :: CCtx) do
  sec_id = 0
  while sec_id < 5 do
    sb = cctx.sections.get(sec_id)
    n  = sb.cursor.get(0)
    i  = 0
    while i < n do
      print(sb.lines.get(i))
      i = i + 1
    end
    sec_id = sec_id + 1
  end
end
```

### Call site migration

All existing `print(s)` calls are replaced with `sec_emit(cctx, SEC_X, s)`:

| Location | Section |
|---|---|
| Preamble in `codegen()` | `SEC_PRE` |
| `emit_enum_def()` | `SEC_TYPES` |
| `emit_struct_defs()` — enum/struct typedefs | `SEC_TYPES` |
| `emit_struct_defs()` → `emit_array_helpers()` | `SEC_HELP` |
| `has_array_attr` block in `codegen()` | `SEC_HELP` |
| `emit_fwd_decls()` | `SEC_FWD` |
| `emit_fn()`, `emit_stmt()`, `emit_block_body()` | `SEC_BODY` |

Functions that do not currently receive `cctx` but need it after this change: `emit_struct_defs`, `emit_fwd_decls`, `emit_enum_def`, `emit_array_helpers`. These gain a `cctx :: CCtx` parameter.

### Out of scope

- `wasm.chasm` — separate backend, left untouched.
- Increasing section capacity dynamically — not needed; bump the constant if 4096 is ever hit.

## Success criteria

- Bootstrap compiler produces identical C output before and after the change (diff clean).
- Any emit function can write to any section by passing a different `sec_id`.
- No `print()` calls remain in the codegen path except inside `flush_sections`.
