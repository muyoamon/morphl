// `cached_check <file.mpl> <cachedir>` — parse + infer with the §9 interface cache on,
// reporting hits, misses and errors.
//
// The cache is the build's business, not the compiler's (§9), so `infer.mpl` only
// supplies the hook: `cx.cdir` empty means off, which is the default everywhere else.
// This driver is the build that turns it on.
$decl I  $import "infer"
$decl T  $import "types"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl argv $call args ()
$decl path $call P.sval ($call at (argv, 0))
$decl dir  $if ($call lt (1, $call alen (argv))) ($call P.sval ($call at (argv, 1))) "."
$decl rf   $call read_file (path)
$decl src  $match rf (
    $case {$prop tag "some"} rf.v,
    $case rf ($call panic ($call concat ("cannot read ", path)))
  )
$decl r  $call I.check_cached (src, $call P.dirname (path), path, dir)
$decl e1 $call nl ($call concat ("errors: ", $call int_to_str ($call Pa.diags.length (r.errs, 0))))
$decl e2 $call nl ($call concat ("cache hits: ", $call int_to_str (r.hits)))
$decl e3 $call nl ($call concat ("cache misses: ", $call int_to_str (r.misses)))
