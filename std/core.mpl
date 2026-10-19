// std/core: what every other `std/` module builds on (STDLIB.md, D1).
//
// Library code in the full language — `Float`, overloads, templates applied by §4.9's
// inference — so stage 0 cannot run it (STDLIB.md, P5) and its tests are compiled.
// Imported as `$decl C $import "std/core"`, with the directory holding `std/` as a
// search root (`mplc -L <dir>`, §4.14).

// ------------------------------------------------------------------ booleans

// An example of `Bool`, for a parameter or storage that takes either tag. §3.2 makes
// `true` and `false` distinct types, so a default of one accepts only it. §4.8a makes a
// `$union` evaluate to its first member, so `$mut $alloc bool` starts `false`.
$decl bool $union (false, true)

// **Strict, not short-circuiting**: §7.1 evaluates every argument, so `$call and (p, q)`
// evaluates `q` even when `p` is false. A guard whose second operand is only safe when the
// first holds needs a nested `$if`.
$decl not $func ($decl b bool) $if b false true
$decl and $func ($decl a bool, $decl b bool) $if a b false
$decl or  $func ($decl a bool, $decl b bool) $if a true b

// ------------------------------------------------------------------- numbers

$decl max_int   $func ($decl a 0, $decl b 0)     $if ($call lt (a, b)) b a
$decl min_int   $func ($decl a 0, $decl b 0)     $if ($call lt (b, a)) b a
$decl max_float $func ($decl a 0.0, $decl b 0.0) $if ($call lt (a, b)) b a
$decl min_float $func ($decl a 0.0, $decl b 0.0) $if ($call lt (b, a)) b a

// §4.8: an overload is resolved at compile time, so these cost a direct call.
$decl max $overload (max_int, max_float)
$decl min $overload (min_int, min_float)

// ---------------------------------------------------------- reading storage

// §5.4 makes a reference transparent only where a value is expected, and a `$decl`
// initializer is not such a place — `$decl y n` aliases. Passing through a parameter
// defaulted to a value is how a cell's contents become an immutable binding. One per
// type rather than a template: §4.9's application would infer `T` as the reference.
$decl ival $func ($decl x 0)   x
$decl fval $func ($decl x 0.0) x
$decl sval $func ($decl x "")  x
$decl bval $func ($decl x bool) x

// -------------------------------------------------------------------- option

// §8's `option T` is the root block's `none` or a `some` carrying the value. A `some` is
// built by `some`; a function answering an option joins the two in an `$if` or `$match`
// (§3.6), as `str_to_int` does.
$decl some $template T $func ($decl x T) { $prop tag "some"  $decl v x }

// Any option, whatever it carries: §5.1 makes `{tag some, v T}` a subtype of the prefix
// `{tag some}`, so these need no generic.
$decl is_some $func ($decl o $union (none, { $prop tag "some" })) $match o (
  $case {$prop tag "some"} true,
  $case o false
)
$decl is_none $func ($decl o $union (none, { $prop tag "some" })) $call not ($call is_some (o))

// The value, or `d` when there is none. `T` comes from `d` (§4.9 reads a generic off a
// parameter default that is exactly it).
$decl or_else $template T $func ($decl o $union (none, { $prop tag "some"  $decl v T }),
                                 $decl d T) $match o (
  $case {$prop tag "some"} o.v,
  $case o d
)

// `f` of the value, or `none`. `A` and `B` come from `f`'s type.
$decl map_opt $template (A, B) $func ($decl o $union (none, { $prop tag "some"  $decl v A }),
                                      $decl f $func ($decl x A) B) $match o (
  $case {$prop tag "some"} $call some ($call f (o.v)),
  $case o none
)

// -------------------------------------------------------------------- result

// §4.15: an expected failure is a value, and `$try x err` is how a caller passes one up.
// A failure that carries something is `{tag err, e E}`, which §5.1 keeps a subtype of the
// root block's `err`, so the same `$try` matches it.
$decl fail $template E $func ($decl x E) { $prop tag "err"  $decl e x }
