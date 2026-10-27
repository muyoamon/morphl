// An emit error: the C prototype takes two parameters and the signature one (§4.16).
// The checker types the signature alone, so only emit sees the disagreement, and `mplc`
// must refuse rather than write the C and exit 0 — which it did while emit's
// diagnostics were all warnings. A library, too, so the note comes first.
$decl labs2 $extern "long labs(long, long)" $func ($decl n 0) 0
$decl f $func () $call labs2 (-3)
