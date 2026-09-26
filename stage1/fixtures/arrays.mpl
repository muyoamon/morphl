// A round-trip fixture for §8's arrays, which had no C backend at all until
// now — `array`, `at` and `alen` were reported as "cannot emit the intrinsic".
//
// None can be a plain C function. `at` answers a **reference** into the
// elements (stage 0 returns `.ref = &a.elems[i]`, and §5.4 reads it through
// where a value is wanted), `alen` is a field read, and `array` needs the
// element's size — so all three are emitted inline, and the array type becomes
// a C struct of a pointer and a length, like §3.1's `Str`.
//
// The element type is always `Str` here because BOOTSTRAP §2 keeps the root
// block monomorphic: `array_t` is `(Int, Str) -> array Str`. So stage 1 has
// exactly one array type, which is also what `args ()` answers.
//
// 3 + 2 + 2 + 5 + 0 = 12.
$decl P $import "../prelude"

$decl main $func ()
  { $decl a  $call array (3, "ab")
    $decl n  $call alen (a)
    // §5.4: a call argument is a value position, so the reference `at` answers
    // is read through here with no explicit deref.
    $decl w0 $call len ($call P.sval ($call at (a, 0)))
    $decl w2 $call len ($call P.sval ($call at (a, 2)))
    $decl b  $call array (5, "")
    $decl m  $call alen (b)
    $decl z  $call len ($call P.sval ($call at (b, 4)))
    $decl r  $call add (n, $call add (w0, $call add (w2, $call add (m, z)))) }.r
