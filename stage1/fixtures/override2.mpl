// §4.12a: an `$override` of a template that an `$override` made. The second splices the first's
// body as the first spliced the base's: the base's items two shifts down, the first override's
// one, its own in place — and each override's names resolve where it is written. Both name a
// `helper`, the module's 10 and this file's 200, so a renaming that did not tell the two levels
// apart would call one for both.
//
// `base`'s sum is 1 + 2, `mid`'s 10 + 2, `top`'s 10 + 200: 3, 12 and 210 make 31410. Compiled
// only: stage 0 leaves `$override` out.

$decl U $import "override2_util"

$decl helper $func () 200

$decl top $override U.mid {
  $prop two $func ($decl x 0) $call helper ()
}

$decl main $func () {
  $decl b   $specialize U.base 0
  $decl m   $specialize U.mid 0
  $decl t   $specialize top 0
  $decl ret $call add ($call mul ($call b.sum (0), 10000),
                $call add ($call mul ($call m.sum (0), 100), $call t.sum (0)))
}.ret
