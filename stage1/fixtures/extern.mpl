// A round-trip fixture for §4.16's `$extern "symbol" sig`. Prints 77.
//
// §9 makes `$extern` "the only door to the platform", and it was the one door
// stage 1 had not built: the form parsed in both stages and nothing after the
// parser knew it. The signature is a **type-only position** (§5.7) whose type is
// an example `$func`, and §4.16's ABI mapping is a function of that type alone —
// so `c_type`, which already maps every morphl type to C, is the whole mapping.
//
// Every shape the mapping names is here: `Int` as `int64_t`, a block as a struct
// in `$decl` order, `&T` as a thin pointer, `Str` as pointer + length, and no
// parameters as `void`. `labs` is bound too, to show that a symbol the C library
// already provides needs nothing linked — and that a signature which *disagrees*
// with the real prototype is caught by the C compiler rather than by this one,
// which is the right place for it.
$decl proto_pt { $decl x 0  $decl y 0 }

// From libc: `long labs(long)`, and on LP64 `int64_t` is `long`, so the mapping
// is exact and the emitted declaration agrees with <stdlib.h>.
$decl labs  $extern "labs"        $func ($decl n 0) 0

// From `extern_host.c`.
$decl add2  $extern "host_add"    $func ($decl a 0, $decl b 0) 0
$decl none0 $extern "host_none"   $func () 0
$decl swap  $extern "host_swap"   $func ($decl v proto_pt) proto_pt
$decl slen  $extern "host_strlen" $func ($decl s "") 0
$decl dref  $extern "host_deref"  $func ($decl p $new 0) 0

// An extern in **value** position rather than called: §7.3 makes a function value
// a pair and a C function has no `void *env`, so the pair points at a generated
// wrapper. Passing one through an ordinary morphl higher-order function is what
// exercises it.
$decl apply2 $func ($decl f add2, $decl a 0, $decl b 0) $call f (a, b)

// `&T` as a thin pointer needs the argument to arrive as storage, which §5.4
// permits precisely because a `&Int` parameter does not expect a value: "Passing
// `0` to a `&Int` parameter is an error; write `$new 0`."
// 25 + 3 + 11 + 4 + 2 + 21 + 11 = 77.
$decl main $func ()
  { $decl c  $new 7
    $decl s  $call swap ({ $decl x 1  $decl y 2 })
    $decl r  $call add2 ($call labs (-25),
                 $call add2 ($call add2 (1, 2),
                 $call add2 ($call none0 (),
                 $call add2 ($call slen ("abcd"),
                 $call add2 (s.x,
                 $call add2 ($call dref (c), $call apply2 (add2, 5, 6))))))) }.r
