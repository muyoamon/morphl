# TODO

## In Spec Features (High Priority):

[x] - Make `$inline` a true non-storage storage descriptor. VM-side `$member $inline { ... } <fieldname>` collapse works for declaration-only blocks/imports, including `$alias <name> $inline $import "<mod-path>"`, and it can resolve dependencies on earlier declarations statically. Runtime-dependent inline logic emits a warning before the hard failure. Direct `$decl x $inline expr` remains ordinary storage as specified.

[x] - Allowing `$static` specifier on function type. Just a function table index inside the static storage. Mutability depend on the operand mutability descriptor e.g., `$decl static_func $static $mut $func () {...};`

[x] - Implement `$alias` as parser-level compile-time expression substitution, including `$import` aliases. Storage/layout/no-runtime-binding behavior follows from substitution; remaining non-storage semantics belong to `$inline`.

[x] - Finish the remaining `$$` directives and metadata named in `SPEC.md`. `$$name`, `$$size`, `$$type`, `$$tag`, and `$$data` exist, but `$$op`, `$$path`, `$$delim`, `$$version`, `$$line`, and `$$col` are still missing, and the spec also reserves `$$syntax`.

[x] - Bring control-flow typing in line with the SPEC. Current typing still treats `$if`/`$while` conditions as `bool`-only in places, returns `{}` for `$while`, allows zero-arg `$exit`, and returns `void` instead of `$never` for `$ret`.

[x] - Make `$new` fully match the SPEC's "any type expression" contract. Declaration-context VM emission supports non-identifier base expressions via the inferred target type, including inline block literals and imported/member-derived block types, with 2-arg initializers. Value-context aggregate `$new` works when consumed through `$member`/`$ref $member`, including imported/member-derived type expressions, arrays, and nested `$ref` initializers.

[x] - Enforce the full `main` entry-point contract from the SPEC. The VM checks `main` return type, but the spec also requires no explicit arguments.

[x] - Makes keywords that take storage-expression as operand e.g., `$set`, `$member` able to take immediate storage-expression operand as valid e.g., `$member {$decl x 0;} x;` Immediate `$member` block operands hoist and evaluate declaration/mutation logic so block-as-value captures final field state, and simple non-captured local declarations can be substituted into later captured field logic. `$set $member <immediate-aggregate> field ...` and `$ref $member <immediate-aggregate> field` materialize the aggregate before use.

## Good to have features (Medium Priority, Not in Spec yet)

[] - Unify C ABI, rather than use C type for external library, use morphl ABI type system, e.g., morphl_i64, morphl_str

[] - Make Error code specific. Currently, only error code has mode: [MXXX] the last three digits is unused.


## Out of Spec Features (Low Priority, Not in order):

[] - `mpldb` morphl debugger, a tool to debug the program.

[] - `$comptime` construct; Evaluate expression at compile-time.

[] - `$extend` keyword. compile-time compound-type extending keyword, does not modify inplace e.g., `$decl new_block $extend block1 block2;` If block2 contains fields with same name in block1, shadow them. The type of new block should be {...block1, ....block2}. Therefore, the shadowed field should be accessible if the new_block is reinterpreted as block1 type. If block2 contains properties that block1 also has, override them.

[] - Expand standard libraries

[] - `$build` keyword, buildsystem as first class construct. `$build <global-expr>` Allowing user to create their own `$global` construct, Therefore allowing user to control the program memory layout.
