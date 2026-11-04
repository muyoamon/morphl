// `prim_value.mpl`'s module: intrinsics named as values here too, so two outputs each need
// the generated wrappers (`emit_pw`) — and a pair made here is called from the entry's file.
$decl tois str_to_int
$decl pick $func () concat
$decl via  $func ($decl s "") {
  $decl o   $call tois (s)
  $decl ret $match o ($case {$prop tag "some"} o.v, $case o 0)
}.ret
