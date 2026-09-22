// A round-trip fixture for §8's *failing* intrinsics, the three that answer an
// option rather than a value: `str_to_int`, `from_code` and `read_file`.
//
// §8 requires a failing operation to produce a value rather than panic, and the
// shape is `<{tag "none"}, {tag "some", v T}>`. §7.5 lays that out as a tag and
// a payload, and §3.6 makes a union a *set* — so which position `some` and
// `none` hold belongs to the call site's interned union, not to the intrinsic.
// That is why these are built at the call site and not emitted as plain calls.
//
// The cases are the ones where the C runtime and stage 0 could drift apart,
// since two implementations of one intrinsic have to agree (§8):
//
//   42            parses                                   ->  42
//   12x           does not                                 ->  -1
//   1_0           `_` separates digits, as stage 0 allows  ->  10
//   233           U+00E9, two bytes of UTF-8 (§3.1)        ->   2
//   55296         a surrogate, which has no encoding       ->  -1
//   a missing path                                         ->   0
//
// 42 - 1 + 10 + 2 - 1 + 0 = 52.

$decl num $func ($decl s "")
  { $decl r $call str_to_int (s)
    $decl out $match r (
        $case {$prop tag "some"} r.v,
        $case r -1
      ) }.out

// §3.1 makes a `Str` bytes, so the length of the encoding is what is checked —
// 233 is U+00E9, which is two bytes in UTF-8.
$decl code_len $func ($decl c 0)
  { $decl r $call from_code (c)
    $decl out $match r (
        $case {$prop tag "some"} ($call len (r.v)),
        $case r -1
      ) }.out

$decl file_len $func ($decl p "")
  { $decl r $call read_file (p)
    $decl out $match r (
        $case {$prop tag "some"} ($call len (r.v)),
        $case r 0
      ) }.out

$decl main $func ()
  { $decl a $call add ($call num ("42"), $call num ("12x"))
    $decl b $call add (a, $call num ("1_0"))
    $decl c $call add (b, $call code_len (233))
    $decl d $call add (c, $call code_len (55296))
    $decl out $call add (d, $call file_len ("/nonexistent/morphl/fixture")) }.out
