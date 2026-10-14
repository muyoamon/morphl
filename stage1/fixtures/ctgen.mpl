// §4.9's compile-time generics: a generic whose value reaches a prop is
// compile-time, its argument must be a constant expression, and its value joins
// the memo key — so `$specialize sized 5` and `$specialize sized 6` are two types,
// and a template can make tags.
//
// 5 + 6 + 3 + 40 + 7 = 61.

// A value parameter: the size is in the type.
$decl sized $template N { $prop size N }

// Tags made by a template. `mk`'s block literal has the prop too, so §4.7 can
// dispatch on what each specialisation built — which works only if the value of
// `N` is in each type, and different values give different types.
$decl tagged $template N {
  $prop mk $func ($decl v 0) { $prop tag N  $decl val v }
}

$decl five $specialize sized 5
$decl six  $specialize sized 6
$decl A $specialize tagged "a"
$decl B $specialize tagged "b"

$decl pick $func ($decl x $union ($call A.mk (0), $call B.mk (0))) $match x (
  $case {$prop tag "a"} x.val,
  $case {$prop tag "b"} $call mul (x.val, 10)
)

// A prop holding a specialisation, with a runtime name as the argument for a
// generic that is *not* compile-time: only its type reaches the result.
$decl seven 7
$decl box $template T { $prop get $func ($decl v T) v }
$decl holder { $prop b $specialize box seven }

$decl main $func ()
  { $decl s $call add (five.size, six.size)
    $decl p $call add ($call pick ($call A.mk (3)), $call pick ($call B.mk (4)))
    $decl r $call add ($call add (s, p), $call holder.b.get (7)) }.r
