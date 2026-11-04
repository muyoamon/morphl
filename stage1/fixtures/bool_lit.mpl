// A boolean literal's node is at its own type, `true` or `false` (§3.2), as its derived type
// says. It was interned at `Bool`, so `$if c 5 true` — `<Int, true>` — was handed a `Bool`
// to inject and emit refused it: "no member of <Int,true> accepts false". Printed by its
// tag, as a union answer is (`main_out`).
$decl main $func () $if ($call lt (2, 1)) 5 true
