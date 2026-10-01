// §3.3 makes a file a block, so its top level may carry `$prop`s — and they used to
// typecheck and then fail to lower, because `lower_top` walks the file type's
// *fields* and a prop is in its props.
//
// Answer 58. Covers the three things a top-level prop can be (§1.1): a scalar read
// from a function body, a prop-only block projected onto, and a `$func`-valued prop
// called through — plus a `$template`, which is what `$specialize` consumes.
$decl P $import "../prelude"

$prop k 11
$prop tagged { $prop tag "t" $prop n 7 }
$prop twice $func ($decl x 0) ($call add (x, x))
$prop box $template T { $prop mk $func ($decl v T) { $decl val v } }

$decl from_decl $func () ($call add (k, tagged.n))
$decl main $func ()
  ($call add ($call from_decl (),
   $call add ($call twice (10),
              ($call ($specialize box 0).mk (20)).val)))
