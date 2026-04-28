# Plan: VM Object/Executable Separation and Link-Time Module Imports

## Summary

Introduce a two-stage VM pipeline with linkable object files (`.mplo`) and runnable executables (`.mplx`).

Change VM import lowering so `$import "path"` no longer inlines the imported module's runtime AST/code into the importer. The frontend still loads and analyzes the imported file for type information, but runtime module resolution moves to the linker. The linker deduplicates modules by canonical source path so every import of the same module uses the same linked module slot and the same module base offset.

Chosen defaults:

- Static linking only
- Explicit compile/link VM CLI modes, while retaining the current one-step VM flow as sugar
- `.mplo` for object files and `.mplx` for executables
- `morphlc -c` compiles only for the VM backend and does not link
- `mpll`, `mplvm`, and `mplinsp` are added as convenience tools alongside `morphlc`

## Public Interface and Artifact Changes

- Add two VM artifact kinds:
  - `.mplo`: non-runnable object containing module-local code/data metadata, imports, exports, and relocations
  - `.mplx`: runnable linked executable containing finalized code/data layout
- Extend the CLI with explicit VM compile and link modes:
  - `morphlc -c` compiles source to `.mplo` only
  - `mpll` links one or more `.mplo` files to `.mplx`
  - `mplvm` runs `.mplx`
  - keep `morphlc` as the current single-shot convenience path that performs compile, link, then run
- Rename the existing bytecode inspection tool from `mbc_reader` to `mplinsp`.
- Keep `$import "path"` syntax unchanged.
- Change `$import` semantics for VM:
  - imported source is still read, parsed, and analyzed for type inference
  - imported runtime code is not spliced into the importer AST/codegen stream
  - link-time resolution assigns one linked module instance per canonical path
- Define canonical module identity as the fully resolved absolute source path of the imported source file.
- Restrict the VM runtime to loading `.mplx` only; `.mplo` is explicitly non-runnable.

## Implementation Changes

### Parser and import preprocessing

- Replace the current `$import` preprocessing behavior that swaps the import string argument for an imported `AST_FILE`.
- Introduce a stable import AST representation that preserves:
  - the source string literal
  - the canonical resolved path
  - a handle to imported module analysis data
- Add compile-session caching for imported modules keyed by canonical path so repeated imports reuse one analyzed module unit.

### Type inference and module metadata

- Preserve the rule that `$import` yields the imported module's block type.
- Infer imported module shape from the analyzed imported file unit rather than an AST subtree inserted into the importer.
- Build `$global.$modules` typing information from canonical module identities.
- Track imported module dependencies as explicit metadata for VM object emission and linking.

### VM object emission

- Add a VM object emitter that writes `.mplo`.
- Compile each source file as one module object with:
  - module identity
  - module-local function table
  - module-local code section
  - module-local static/global layout metadata
  - export table for importable top-level declarations
  - import table keyed by canonical module path
  - relocation records for merged-table references
- Stop emitting imported module initialization inline into the importer's top-level body.
- Preserve module-local indices and offsets in `.mplo`; defer executable-wide addressing to the linker.

### Linker

- Add a static VM linker that consumes one or more `.mplo` files and produces one `.mplx`.
- Resolve the module graph by canonical path and deduplicate repeated imports of the same module.
- Assign final executable-wide:
  - function indices
  - global-frame offsets
  - module slots
  - static slots
  - trait/property dispatch table offsets
  - native symbol table indices
- Apply relocation patching for any operand or table entry that refers to merged executable-wide layout.
- Synthesize executable startup so that:
  - executable global metadata is initialized first
  - linked module init runs once per deduplicated module in dependency order
  - root program top-level execution runs after module initialization
- Emit one final `$global.$modules` table in the executable, with one slot per deduplicated linked module instance.

### Runtime

- Keep the VM runtime simple: it loads finalized `.mplx` only.
- Reject `.mplo` in `morphl_vm_program_load`.
- Keep native symbol resolution at executable load time; native references are merged by the linker into one executable-level native table.

### CLI and user workflow

- Update CLI help and behavior so that, for the VM backend, `morphlc -c` means compile only and stops before linking.
- Add convenience executables:
  - `mpll` for linking `.mplo` to `.mplx`
  - `mplvm` for running `.mplx`
  - `mplinsp` as the renamed bytecode inspection tool
- Retain the existing one-shot `morphlc` VM workflow as compatibility sugar.
- Make output naming reflect artifact type defaults:
  - `morphlc -c` object output defaults to `.mplo`
  - linked executable output defaults to `.mplx`

## Test Plan

- Parser/type tests:
  - `$import` returns imported module type without replacing the importer-visible node with an embedded `AST_FILE`
  - repeated imports of the same path reuse the same canonical analyzed module unit
  - relative-path imports that normalize to the same canonical path deduplicate correctly
  - `$global.$modules` type shape reflects canonical module deduplication
- VM object/link tests:
  - compile a source file to `.mplo`
  - reject direct execution of `.mplo`
  - link one `.mplo` into `.mplx` and execute successfully
  - link multiple objects that import the same module and verify all import sites use the same module slot/base offset
  - verify module init side effects run once even when a module is imported from multiple sites or objects
  - verify cross-module field access, function calls, and statics work after relocation
  - verify direct module binding access and `$global.$modules.<mod>` resolve to the same underlying module storage
  - verify unresolved module or symbol imports fail at link time
- CLI tests:
  - `morphlc -c` writes `.mplo` and does not link or run
  - `mpll` writes `.mplx`
  - `mplvm` runs `.mplx`
  - `mplinsp` replaces `mbc_reader`
  - one-shot VM invocation through `morphlc` still works and behaves as compile + link + run

## Incremental Tasks

Use these milestones as the implementation order and as the matching checklist entries in `TODO.md`:

1. Split VM artifacts into non-runnable `.mplo` object files and runnable `.mplx` executables, including header-level kind/version validation and runtime rejection of `.mplo` inputs.
2. Change VM import lowering so `$import` keeps canonical-path/type-analysis metadata without replacing the importer-visible node with an embedded `AST_FILE` for runtime emission.
3. Add compile-session imported-module caching and canonical-path identity tracking so repeated imports of the same module reuse one analyzed module unit and one link-time module identity.
4. Emit `.mplo` from the VM backend with module-local code/function/global metadata, import/export tables, relocation records, and module-init metadata.
5. Add a static VM linker (`mpll`) that consumes `.mplo` inputs, resolves/deduplicates modules by canonical path, assigns final executable-wide indices/offsets, and writes `.mplx`.
6. Synthesize linked startup/module initialization so each deduplicated module initializes once in dependency order before root top-level execution.
7. Make VM CLI/tooling follow the new split: `morphlc -c` compiles only to `.mplo`, `morphlc` remains compile+link+run sugar, `mplvm` runs `.mplx`, and `mbc_reader` is renamed to `mplinsp`.
8. Rework `$global.$modules` and imported module access so all import sites of the same canonical module resolve to the same linked module slot/base offset and shared module statics.
9. Add parser, typing, linker, runtime, and CLI regression coverage for object/executable separation, once-only module initialization, canonical-path deduplication, and the new VM tools.

## Assumptions and Defaults

- One source file maps to one VM module object.
- The final linked executable keeps a single global frame and a single global function table.
- Relative intra-function jumps and local frame offsets do not require relocation.
- Any operand or metadata entry that refers to executable-wide merged tables or offsets does require relocation.
- Dynamic bytecode module loading is out of scope for this feature.
- The C backend is unchanged.
