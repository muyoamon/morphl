# Feature Proposal: VM Object/Executable Separation and Link-Time Module Imports

---

## 1. Problem Statement

The current VM backend compiles one source tree directly into one runnable bytecode image. `$import` works by loading the target source file during preprocessing, parsing it immediately, and replacing the import argument with the imported file AST. The VM emitter then emits the imported module's initialization code inline into the importing program.

This is sufficient for simple whole-program compilation, but it breaks down for module reuse:

- the same imported module can be emitted multiple times if referenced from multiple import sites
- import identity is tied to the importer's lowered AST/codegen path rather than a stable module identity
- module initialization is not modeled as a once-per-module operation
- there is no linkable VM object format
- cross-module layout and call resolution are fixed too early, during emission instead of linking

The VM backend needs a proper object/executable split so modules can be compiled independently, linked together, deduplicated by identity, and initialized once.

---

## 2. Current Import Behavior and Its Limits

Today, `$import "path"` does two jobs at once:

- frontend analysis: load the imported file so the compiler can infer its structural type
- runtime lowering: inline the imported module into the importing compilation unit's emitted VM program

That coupling creates the wrong runtime model for reusable modules. For VM code generation, imported modules should not be treated as textual or AST-level runtime inclusion. The compiler still needs imported source to compute types, but runtime composition should happen at link time.

In particular, two different import sites that resolve to the same module path should not produce two distinct module instances or two distinct offsets in the final executable.

---

## 3. Proposed Artifact Model

This proposal introduces two VM artifact kinds:

### `.mplo` - MorphL VM Object

`.mplo` is a non-runnable, linkable VM object file.

It contains:

- object kind and version
- canonical module identity
- module-local function table
- module-local code section
- module-local global/static layout metadata
- export table
- import table
- relocation records
- string table
- native symbol table entries as needed
- module init entry symbol

`.mplo` preserves module-local numbering and layout where possible. It does not commit to final executable-wide function indices or global offsets.

### `.mple` - MorphL VM Executable

`.mple` is the runnable linked VM artifact.

It contains:

- finalized executable-wide function table
- finalized executable-wide global frame layout
- finalized code section
- resolved module table
- linked startup/init sequence
- merged string and native symbol tables

The VM runtime loads `.mple` only.

---

## 4. Proposed `$import` Semantics

The surface syntax remains:

```morphl
$import "path/to/module.mpl"
```

The semantic change is internal:

- the frontend still resolves the path, loads the imported file, parses it, and analyzes it for type information
- `$import` still has the imported module's block type
- the importer does not embed the imported module's runtime AST/code into its own emitted VM program
- instead, the compiler records an import dependency on the canonical imported module identity
- the linker resolves that dependency and assigns the final module slot and base offset

This preserves the language-level typing model while changing the runtime composition model from compile-time inlining to link-time resolution.

---

## 5. Canonical Module Identity

To support deduplication and single initialization, the linker needs a stable notion of module identity.

This proposal defines module identity as:

- the fully resolved absolute source path of the imported file

Consequences:

- imports that resolve to the same canonical path refer to the same linked module instance
- import binding names do not affect module identity
- every linked executable has at most one module slot/base offset for a given canonical module path

This identity is used for:

- dependency tracking in `.mplo`
- import deduplication during linking
- final `$global.$modules` layout
- once-only module initialization

---

## 6. Linker Responsibilities

The linker becomes responsible for assembling the final VM executable.

Its responsibilities are:

- load one or more `.mplo` inputs
- resolve the module dependency graph
- deduplicate modules by canonical path
- assign final executable-wide function indices
- assign final executable-wide global-frame offsets
- assign final module slots and module base offsets
- merge string and native symbol tables
- apply relocation records
- synthesize startup so module initialization runs once per linked module before root execution

### Relocation Scope

Relocation is required for references whose final value depends on executable-wide merged layout.

This includes:

- function table indices used by calls
- executable-wide global or static offsets
- module slot and module base references
- trait/property dispatch table references
- cleanup thunk indices when they participate in merged executable-wide numbering
- merged native symbol table indices

Relative jumps within a finalized function body and local frame offsets inside a function do not need executable-level relocation.

---

## 7. Executable Layout and Module Initialization

The final executable keeps a simple runtime model:

- one executable-wide global frame
- one executable-wide function table
- one executable-wide module table

Each linked module contributes:

- module-local code and metadata
- one module init entry
- exported declarations and static storage metadata

During linking, the executable startup sequence is synthesized as:

1. initialize executable global metadata
2. initialize each deduplicated module exactly once in dependency order
3. execute the root program top-level body or synthesized `main` dispatch

Because repeated imports of the same canonical module resolve to one linked module instance, all import sites share the same module slot and base offset.

That gives the desired semantics:

- one module instance per linked executable
- one initialization pass per linked module
- stable cross-module addressing

---

## 8. CLI and User Workflow

This proposal adds explicit compile and link steps for VM builds, while keeping `morphlc` as the convenience front door.

Recommended workflow:

- compile source file to object with `morphlc -c`: `.mplo`
- link one or more objects to executable with `mpll`: `.mple`
- run `.mple` with `mplvm`

The main `morphlc` executable should remain the one-shot convenience path that internally performs:

- compile to object
- link to executable
- execute linked executable

Additional convenience tools:

- `mpll`: link `.mplo` inputs into a `.mple`
- `mplvm`: execute a `.mple`
- `mplinsp`: inspect VM bytecode artifacts

`mplinsp` is the renamed successor to the current `mbc_reader` tool.

For the VM backend specifically, `morphlc -c` changes meaning from "compile without execution" to "compile only, without linking". This aligns `-c` with the new object/executable split.

This keeps the current high-level `morphlc` user experience available while exposing explicit tools for compilation, linking, execution, and inspection.

---

## 9. Compatibility and Transition

Source compatibility is preserved:

- `$import` syntax does not change
- import typing behavior does not change from the user's perspective

Backend/runtime behavior does change:

- `.mplo` is introduced as a new non-runnable VM artifact
- `.mple` becomes the runnable VM artifact
- the runtime should reject `.mplo`
- the current VM output path defaults should move toward artifact-specific extensions
- `morphlc -c` for the VM backend becomes object-only compilation
- `mpll`, `mplvm`, and `mplinsp` are added as convenience tools
- `mbc_reader` is renamed to `mplinsp`

The main behavioral change is desirable and intentional:

- repeated imports of the same canonical module no longer behave like repeated inlined module emission
- they resolve to one linked module instance with one offset and one initialization

---

## 10. Non-Goals for V1

This proposal does not include:

- dynamic runtime loading of MorphL bytecode modules
- a redesign of source-level import syntax
- changes to the C backend
- speculative changes to the language spec beyond documenting the new VM import/runtime model

V1 is strictly about static linking, object/executable separation, and once-only module initialization in the VM backend.

---

## 11. Implementation Direction

The intended implementation shape is:

- parser/frontend:
  - stop replacing `$import` with imported runtime AST for downstream VM emission
  - keep imported-module loading for analysis
  - cache imported module analysis by canonical path
- type inference:
  - infer imported module block type from analyzed imported module units
  - derive `$global.$modules` typing metadata from canonical module identities
- VM backend:
  - add `.mplo` emission with import/export/relocation metadata
  - stop inline emission of imported module init into importer top-level code
- linker:
  - resolve and deduplicate modules
  - assign final executable-wide indices and offsets
  - patch relocations
  - synthesize once-only module init ordering
- runtime:
  - load `.mple` only

---

## 12. Open Questions

None for this proposal.

The chosen defaults are:

- static linking only
- explicit compile/link CLI modes, with one-shot `morphlc` flow retained as sugar
- `.mplo` object files and `.mple` executable files
- `morphlc -c` means compile-only for VM
- `mpll`, `mplvm`, and `mplinsp` are provided as convenience tools
