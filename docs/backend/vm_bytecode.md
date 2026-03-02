# Morphl VM bytecode format

This document describes the binary output produced by `morphlc --backend vm`.

## File layout (little-endian)

1. **Magic** (`4 bytes`): ASCII `MVMB`
2. **Version major** (`u16`)
3. **Version minor** (`u16`)
4. **Flags/reserved** (`u32`, currently `0`)
5. **String table count** (`u32`)
6. **String table entries** (repeated):
   - string byte length (`u32`)
   - UTF-8/raw bytes (`length` bytes, no trailing `\0`)
7. **Metadata count** (`u32`)
8. **Metadata entries** (repeated):
   - key string index (`u32`)
   - value string index (`u32`)
9. **Code length** (`u32`)
10. **Code bytes** (`code length` bytes)

## String table

The table is interned and deduplicated for:
- identifiers
- literals
- operator names (`$add`, `$set`, `$call`, ...)
- metadata keys and values

Operators are emitted **verbatim** as Morphl operator symbols.

## Metadata

Current metadata keys:
- `backend = morphl-vm-bytecode`
- `format_version = 1.0`
- `operators = runtime-verbatim`

## Opcodes

| Opcode | Mnemonic | Payload | Description |
|---|---|---|---|
| `0x00` | `HALT` | none | Stop execution. |
| `0x01` | `PUSH_NULL` | none | Push null sentinel. |
| `0x02` | `PUSH_LITERAL` | `u32 string_index` | Push literal token text. |
| `0x03` | `PUSH_IDENT` | `u32 string_index` | Push identifier text. |
| `0x04` | `MAKE_GROUP` | `u32 arity` | Pack the previous `arity` values as a group. |
| `0x05` | `SET_SLOT` | `u32 name_index` | Pop/assign top value to a source-order stack slot name (used for `$decl`). |
| `0x06` | `OPERATOR` | `u32 op_name_index` | Apply runtime Morphl operator by verbatim symbol name. |
| `0x07` | `NODE_META` | `u8 ast_kind`, `u32 op_name_index`, `u32 argc` | Fallback descriptor for node kinds not lowered yet. |


## Compile-time vs runtime operators

The VM emitter treats compile-time operators as already resolved by the compiler pipeline.

- Compile-time operators (e.g. `$decl`, `$import`, `$syntax`, `$prop`) are not emitted as `OPERATOR` instructions.
- `$decl` is lowered to stack-oriented behavior: emit RHS value, then `SET_SLOT <name>`.
- Runtime operators (e.g. `$add`, `$set`, `$call`, etc.) are emitted verbatim through `OPERATOR` with a string table index.

## Example invocation

```bash
./build/src/morphlc --backend vm examples/program.src
```

This writes `out.mbc`.
