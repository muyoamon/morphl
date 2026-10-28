// A generic whose argument is a template or a module, in a `$func` and in a builder. A
// template's value is unit and lowering keeps *which* template on the binding, so two
// things dropped it:
// - a `$func` capturing such a generic rebound it as a plain capture (`cap_env`), and a
//   `$specialize` of it inside the `$func` found no template — with no self-reach at all;
// - a self-reaching template's builder (`spec_knot`) takes its generics as parameters, read
//   off the memo key, and a template argument's key was its unit. It is the template type
//   at inference's identity now (`arg_keys`), which is also what inference keys it by, and
//   what keeps `ctr (box, 5)` and `ctr (twice, 5)` two builders.
// A module argument needed neither: its props are in its type, its `$decl`s in its record.
//
// The digits: a captured template generic (5); one in a builder (6); a second template at
// the same position, its own builder (8); a module generic in a builder (7), and with a
// direct reach (3). 56873.

$decl box   $template T { $decl v T }
$decl twice $template T { $decl v $call mul (T, 2) }

// 1. No self-reach: `mk` captures `B`.
$decl made $template (B, T) {
  $decl n  T
  $decl mk $func () $specialize B n
}

// 2, 3. `next` reaches `ctr` again, so `ctr` is a builder taking `B`.
$decl ctr $template (B, T) {
  $decl n    T
  $decl b    $specialize B n
  $decl next $func () $specialize ctr (B, $call add (n, 1))
}

// 4, 5. A module.
$decl ops { $prop inc $func ($decl x 0) $call add (x, 1) }
$decl step $template ($decl M ops, T) {
  $decl n    T
  $decl next $func () $specialize step (M, $call M.inc (n))
}
$decl upto $template (M, T) {
  $decl n T
  $decl m $if ($call lt (n, 3)) ($specialize upto (M, $call M.inc (n))).m n
}

$decl d $func ($decl acc 0, $decl x 0) $call add ($call mul (acc, 10), x)

$decl main $func () {
  $decl a   ($call ($specialize made (box, 5)).mk ()).v
  $decl b   ($call ($specialize ctr (box, 5)).next ()).b.v
  $decl c   $call sub (($call ($specialize ctr (twice, 5)).next ()).b.v, 4)
  $decl e   ($call ($call ($specialize step (ops, 5)).next ()).next ()).n
  $decl g   ($specialize upto (ops, 0)).m
  $decl ret $call d ($call d ($call d ($call d (a, b), c), e), g)
}.ret
