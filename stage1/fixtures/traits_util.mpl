// The module half of `traits_split.mpl`: the conforming types, and functions over the
// trait, live here, so their members are defined in this output and called through the
// tables in the shared header.

$decl shape_proto { $prop area $func () 0 }

$decl rect { $decl w 3  $decl h 4
  $prop area $func () $call mul (rect.w, rect.h)
}
$decl sq { $decl side 5
  $prop area $func () $call mul (sq.side, sq.side)
}

$decl total $func ($decl a $traitsof shape_proto, $decl b $traitsof shape_proto)
  $call add ($call a.area (), $call b.area ())

$decl one $func ($decl s $traitsof shape_proto) $call s.area ()

$decl answer $call total (rect, sq)
