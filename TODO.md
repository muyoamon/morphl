# TODO

## Implementing Features (Highest Priority):

[] - Finish `$overload` follow-up work: lazy `$inline $overload` semantics and C backend support.

## In Spec Features (High Priority):

## Good to have features (Medium Priority, Not in Spec yet)

[] - Unify ABI: rather than use C type for external library, use morphl ABI type system, e.g., morphl_i64, morphl_str

[] - Make error code specific. Currently, only error code has mode: [MXXX] the last three digits is unused.

[] - `$comment` and/or `//` treat the following tokens as comments (drop node) until new line.

## Out of Spec Features (Low Priority, Not in order):

[] - `mpldb` morphl debugger, a tool to debug the program.

[] - `$comptime` construct; Evaluate expression at compile-time.

[] - `$extend` keyword. compile-time compound-type extending keyword, does not modify inplace e.g., `$decl new_block $extend block1 block2;` If block2 contains fields with same name in block1, shadow them. The type of new block should be {...block1, ....block2}. Therefore, the shadowed field should be accessible if the new_block is reinterpreted as block1 type. If block2 contains properties that block1 also has, override them.

[] - Expand standard libraries

[] - `$build` keyword, buildsystem as first class construct. `$build <global-expr>` Allowing user to create their own `$global` construct, Therefore allowing user to control the program memory layout.

## Completed

[x] - Split VM artifacts into non-runnable `.mplo` object files and runnable `.mplx` executables, including header-level kind/version validation and runtime rejection of `.mplo` inputs.

[x] - Change VM import lowering so `$import` keeps canonical-path/type-analysis metadata without replacing the importer-visible node with an embedded `AST_FILE` for runtime emission.

[x] - Add compile-session imported-module caching and canonical-path identity tracking so repeated imports of the same module reuse one analyzed module unit and one link-time module identity.

[x] - Emit `.mplo` from the VM backend with module-local code/function/global metadata, import/export tables, relocation records, and module-init metadata.

[x] - Finish `mpll` object-graph validation and startup synthesis so linked executables enter through a synthesized wrapper, reject missing module objects, and prepare for once-only module init ordering.

[x] - Resolve cross-object function symbols in `mpll` using object export metadata plus relocation records so imported module functions can be linked by canonical module identity instead of remaining local-only.

[x] - Add linker support for executable-wide global/static/module-slot layout and the corresponding relocation kinds so distinct objects can share one finalized global frame safely.

[x] - Switch VM module init from inline-import behavior to true once-only linked module initialization, with dependency-ordered startup and no duplicate imported-module side effects.

[x] - Finish linker/runtime integration for shared module instances so `$global.$modules` and imported module bindings resolve to the same linked module base offset and shared statics.

[x] - Synthesize linked startup/module initialization so each deduplicated module initializes once in dependency order before root top-level execution.

[x] - Remove implicit VM `main` dispatch support so linked and direct VM execution use explicit root top-level execution only, with any future entry selection handled by build configuration rather than backend synthesis.

[x] - Make VM CLI/tooling follow the new split: `morphlc -c` compiles only to `.mplo`, `morphlc` remains compile+link+run sugar, `mplvm` runs `.mplx`, and `mbc_reader` is renamed to `mplinsp`.

[x] - Rework `$global.$modules` and imported module access so all import sites of the same canonical module resolve to the same linked module slot/base offset and shared module statics.

[x] - Add parser, typing, linker, runtime, and CLI regression coverage for object/executable separation, once-only module initialization, canonical-path deduplication, and the new VM tools.

[x] - Make `$inline` a true non-storage storage descriptor. VM-side `$member $inline { ... } <fieldname>` collapse works for declaration-only blocks/imports, including `$alias <name> $inline $import "<mod-path>"`, and it can resolve dependencies on earlier declarations statically. Runtime-dependent inline logic emits a warning before the hard failure. Direct `$decl x $inline expr` remains ordinary storage as specified.

[x] - Allowing `$static` specifier on function type. Just a function table index inside the static storage. Mutability depend on the operand mutability descriptor e.g., `$decl static_func $static $mut $func () {...};`

[x] - Implement `$alias` as parser-level compile-time expression substitution, including `$import` aliases. Storage/layout/no-runtime-binding behavior follows from substitution; remaining non-storage semantics belong to `$inline`.

[x] - Finish the remaining `$$` directives and metadata named in `SPEC.md`. `$$name`, `$$size`, `$$type`, `$$tag`, and `$$data` exist, but `$$op`, `$$path`, `$$delim`, `$$version`, `$$line`, and `$$col` are still missing, and the spec also reserves `$$syntax`.

[x] - Bring control-flow typing in line with the SPEC. Current typing still treats `$if`/`$while` conditions as `bool`-only in places, returns `{}` for `$while`, allows zero-arg `$exit`, and returns `void` instead of `$never` for `$ret`.

[x] - Make `$new` fully match the SPEC's "any type expression" contract. Declaration-context VM emission supports non-identifier base expressions via the inferred target type, including inline block literals and imported/member-derived block types, with 2-arg initializers. Value-context aggregate `$new` works when consumed through `$member`/`$ref $member`, including imported/member-derived type expressions, arrays, and nested `$ref` initializers.

[x] - Align the VM and `SPEC.md` on explicit entry semantics: remove implicit `main` dispatch, treat top-level execution as the default entry model, and leave future entry selection to explicit build configuration.

[x] - Makes keywords that take storage-expression as operand e.g., `$set`, `$member` able to take immediate storage-expression operand as valid e.g., `$member {$decl x 0;} x;` Immediate `$member` block operands hoist and evaluate declaration/mutation logic so block-as-value captures final field state, and simple non-captured local declarations can be substituted into later captured field logic. `$set $member <immediate-aggregate> field ...` and `$ref $member <immediate-aggregate> field` materialize the aggregate before use.

[x] - Finish the remaining VM-side `$ref` generalization work. The current tagged/storage-handle model covers stack/static/heap refs, nullability, identity equality, and direct rebinding/write-through cases, but helper paths and edge cases still need broader storage-class-neutral coverage and regression tests.

[x] - Finish the remaining `$defer`, `$heap`, and `$free` work in the VM. Alias-safe `$free` cleanup (compile-time alias resolution), function-body `$defer` (fires before `$ret` and implicit return), and `$new` template cleanup (fresh block instance inherits `$defer` from the template) are implemented. Runtime per-allocation cleanup-thunk model implemented: `$free y` now works when `y` is a runtime copy of a heap handle (not a compile-time alias).

[x] - Add first-class source-level `$overload` support in the VM pipeline. Parser accepts builtin `$overload`; typing builds overload types, resolves projected candidates at use sites, supports whole-object `$set`, and VM lowering handles stored overload values plus selected-candidate loads/stores. C backend currently rejects source-level `$overload`, and lazy `$inline $overload` semantics remain follow-up work.

