// `cached_bench <file.mpl> <cachedir>` — parse + infer with the §9 interface cache,
// reporting hits and misses. A `-` for the directory turns the cache off, which is the
// uncached baseline.
//
// **Compiled-only, and that is the point.** `cached_check.mpl` is the same measurement
// under stage 0; this one exists to ask whether the cache's remaining gap to the
// predicted speedup is interpretation or design. The work sits in `main` because a
// compiled driver needs one, and §3.3's top-level items run from `mpl_init` *before*
// `main`, so a driver written both ways does its work twice.
$decl I  $import "infer"
$decl Pa $import "parser"
$decl P  $import "prelude"

$decl nl $func ($decl s "") $do ($call print (s)) ($call print ("\n"))

$decl main $func ()
  { $decl argv $call args ()
    $decl path $call P.sval ($call at (argv, 0))
    $decl dir0 $if ($call lt (1, $call alen (argv))) ($call P.sval ($call at (argv, 1))) "-"
    $decl dir  $if ($call eq_str (dir0, "-")) "" dir0
    $decl rf   $call read_file (path)
    $decl src  $match rf (
        $case {$prop tag "some"} rf.v,
        $case rf ($call panic ($call concat ("cannot read ", path)))
      )
    $decl r    $call I.check_cached (src, $call P.dirname (path), path, dir)
    $decl a    $call nl ($call concat ("errors: ",
                   $call int_to_str ($call Pa.diags.length (r.errs, 0))))
    $decl b    $call nl ($call concat ("hits: ", $call int_to_str (r.hits)))
    $decl c    $call nl ($call concat ("misses: ", $call int_to_str (r.misses)))
    $decl out  "" }.out
