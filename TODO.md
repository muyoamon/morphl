# TODO

## In Spec Features (High Priority):

[] - Make `$inline` a true non-storage storage descriptor. `$member $inline { ... } <fieldname>` should collapse to value of `<fieldname>` allowing `$alias <name> $inline $import "<mod-path>"` to be used as import-as-alias e.g. `$alias type $inline $import "stdlib/typing"; $decl x $mut $member type i8; $decl y $const $member type f64;`

[] - Allowing `$static` specifier on function type. Just a function table index inside the static storage. Mutability depend on the operand mutability descriptor e.g., `$decl static_func $static $mut $func () {...};`


## Out of Spec Features (Low Priority):

[] - `$comptime` construct; Evaluate expression at compile-time.

[] - `$extend` keyword. compile-time compound-type extending keyword, does not modify inplace e.g., `$decl new_block $extend block1 block2;` If block2 contains fields with same name in block1, shadow them. The type of new block should be {...block1, ....block2}. Therefore, the shadowed field should be accessible if the new_block is reinterpreted as block1 type. If block2 contains properties that block1 also has, override them.

[] - Expand standard libraries

[] - `$build` keyword, buildsystem as first class construct. `$build <global-expr>` Allowing user to create their own `$global` construct, Therefore allowing user to control the program memory layout.
