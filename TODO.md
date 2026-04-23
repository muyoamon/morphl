# TODO

## In Spec Features (High Priority):

[] - Make `$inline` a true non-storage storage descriptor. `$member $inline { ... } <fieldname>` should collapse to value of `<fieldname>` allowing `$alias <name> $inline $import "<mod-path>"` to be used as import-as-alias e.g. `$alias type $inline $import "stdlib/typing"; $decl x $mut $member type i8; $decl y $const $member type f64;` The inlined block should not have runtime storage, therefore its inside logic should not be evaluate. If the field inlining depends on other field or prior logic inside the block, throw a warning (bad usage) and try to resolve its dependency statically.

[] - Allowing `$static` specifier on function type. Just a function table index inside the static storage. Mutability depend on the operand mutability descriptor e.g., `$decl static_func $static $mut $func () {...};`

[] - Implement `$alias` end-to-end as the SPEC defines it: compile-time expression substitution with no runtime storage, no shape contribution, and support for `$import` aliases.

[] - Finish the remaining `$$` directives and metadata named in `SPEC.md`. `$$name`, `$$size`, `$$type`, `$$tag`, and `$$data` exist, but `$$op`, `$$path`, `$$delim`, `$$version`, `$$line`, and `$$col` are still missing, and the spec also reserves `$$syntax`.

[] - Bring control-flow typing in line with the SPEC. Current typing still treats `$if`/`$while` conditions as `bool`-only in places, returns `{}` for `$while`, allows zero-arg `$exit`, and returns `void` instead of `$never` for `$ret`.

[] - Make `$new` fully match the SPEC's "any type expression" contract. Type inference accepts arbitrary base expressions, but VM emission still requires an identifier-backed template and does not cover the full generic surface described in the spec.

[] - Enforce the full `main` entry-point contract from the SPEC. The VM checks `main` return type, but the spec also requires no explicit arguments.

[] - Makes keywords that take storage-expression as operand e.g., `$set`, `$member` able to take immediate storage-expression operand as valid e.g., `$member {$decl x 0;} x;` Unlike the inlined counterpart the immediate block here should have its inside logic evaluated following the spec of block-as-value is capturing last state of the block.

## Out of Spec Features (Low Priority):

[] - `$comptime` construct; Evaluate expression at compile-time.

[] - `$extend` keyword. compile-time compound-type extending keyword, does not modify inplace e.g., `$decl new_block $extend block1 block2;` If block2 contains fields with same name in block1, shadow them. The type of new block should be {...block1, ....block2}. Therefore, the shadowed field should be accessible if the new_block is reinterpreted as block1 type. If block2 contains properties that block1 also has, override them.

[] - Expand standard libraries

[] - `$build` keyword, buildsystem as first class construct. `$build <global-expr>` Allowing user to create their own `$global` construct, Therefore allowing user to control the program memory layout.
