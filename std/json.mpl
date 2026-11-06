// std/json: JSON text (RFC 8259) read into a value, and a value written back as text.
//
//   $decl r $call J.parse ("{\"a\": [1, true]}")       // {tag ok, v <value>, pos} or the failure
//   $call J.int_or ($call J.at ($call J.get (r.v, "a"), 0), -1)          // 1
//   $call J.text ($call J.obj ($call strs.of_one ("a"), …))               // {"a":1}
//
// A value is a union with one member per kind of JSON value, so a `$match` takes it apart. A
// number keeps its text, since JSON's numbers are not morphl's (`int_or` reads it as an
// `Int`); an object keeps its members in the order written, its keys and its values in two
// lists side by side, and a key written twice is there twice (`get` finds the first).
//
// Reading through `get`, `at` and the `…_or` accessors never fails: a member that is not
// there, or a value of another kind, reads as `null` or as the default given — which is how a
// JSON protocol treats an absent field, and lets a message be read without a match per field.
// A malformed text is the one expected failure (§4.15): `parse` answers
// `{tag err, msg, pos}`, `pos` the byte where it was found.

$decl C $import "std/core"
$decl L $import "std/list"
$decl S $import "std/str"

$decl strs $specialize L.list ""
$decl cl   strs.cell

// §5.5: an array or an object holds values of the type being made, through storage.
$decl value $union (
  { $prop tag "null" },
  { $prop tag "bool"  $decl v C.bool },
  { $prop tag "num"   $decl text "" },
  { $prop tag "str"   $decl v "" },
  { $prop tag "arr"   $decl items $alloc ($specialize L.list value).node },
  { $prop tag "obj"   $decl keys $alloc strs.node  $decl vals $alloc ($specialize L.list value).node }
)
$decl values $specialize L.list value
$decl vl     values.cell

// --------------------------------------------------------------- making one

// A member made a `value`, as a call argument injects it (§3.6).
$decl jv $func ($decl x value) x

// `value` evaluates to its first member (§4.8a).
$decl null    value
$decl boolean $func ($decl b C.bool) $call jv ({ $prop tag "bool"  $decl v b })
$decl num     $func ($decl n 0) $call jv ({ $prop tag "num"  $decl text $call int_to_str (n) })
$decl str     $func ($decl s "") $call jv ({ $prop tag "str"  $decl v s })
$decl arr     $func ($decl xs values.node) $call jv ({ $prop tag "arr"  $decl items $alloc xs })
$decl obj     $func ($decl ks strs.node, $decl vs values.node)
  $call jv ({ $prop tag "obj"  $decl keys $alloc ks  $decl vals $alloc vs })

// An object built a member at a time, in order: `put` each, then `build ()`.
$decl object $func () {
  $decl o   {
    $decl ks    $mut $alloc strs.node
    $decl vs    $mut $alloc values.node
    $prop put   $func ($decl k "", $decl v value)
      $do ($set o.ks ($call cl.cons (k, $call cl.val (o.ks))))
          ($do ($set o.vs ($call vl.cons (v, $call vl.val (o.vs)))) ())
    $prop build $func ()
      $call obj ($call cl.reverse ($call cl.val (o.ks), strs.nil),
                 $call vl.reverse ($call vl.val (o.vs), values.nil))
  }
  $decl ret o
}.ret

// An array built an element at a time, in order: `push` each, then `build ()`.
$decl array_of $func () {
  $decl a   {
    $decl xs    $mut $alloc values.node
    $prop push  $func ($decl v value) $do ($set a.xs ($call vl.cons (v, $call vl.val (a.xs)))) ()
    $prop build $func () $call arr ($call vl.reverse ($call vl.val (a.xs), values.nil))
  }
  $decl ret a
}.ret

// --------------------------------------------------------------- reading one

// "null", "bool", "num", "str", "arr" or "obj".
$decl kind $func ($decl v value) $match v (
  $case {$prop tag "null"} "null",
  $case {$prop tag "bool"} "bool",
  $case {$prop tag "num"}  "num",
  $case {$prop tag "str"}  "str",
  $case {$prop tag "arr"}  "arr",
  $case v "obj"
)
$decl is_null $func ($decl v value) $match v ($case {$prop tag "null"} true, $case v false)

$decl find_key $func ($decl ks strs.node, $decl vs values.node, $decl k "") $match ks (
  $case {$prop tag "cons"}
    $if ($call eq_str (ks.head, k)) ($call vl.head (vs))
        ($call find_key ($call cl.val (ks.tail), $call vl.rest (vs), k)),
  $case ks null
)
$decl has_key $func ($decl ks strs.node, $decl k "") $match ks (
  $case {$prop tag "cons"} $if ($call eq_str (ks.head, k)) true ($call has_key (ks.tail, k)),
  $case ks false
)

// Member `k` of an object, or `null`.
$decl get $func ($decl v value, $decl k "") $match v (
  $case {$prop tag "obj"} $call find_key ($call cl.val (v.keys), $call vl.val (v.vals), k),
  $case v null
)
// Whether an object has member `k`, which `get` cannot tell from a member that is `null`.
$decl has $func ($decl v value, $decl k "") $match v (
  $case {$prop tag "obj"} $call has_key ($call cl.val (v.keys), k),
  $case v false
)

$decl nth_or_null $func ($decl xs values.node, $decl i 0) $match xs (
  $case {$prop tag "cons"}
    $if ($call eq (i, 0)) xs.head ($call nth_or_null (xs.tail, $call sub (i, 1))),
  $case xs null
)
// Element `i` of an array, or `null`.
$decl at $func ($decl v value, $decl i 0) $match v (
  $case {$prop tag "arr"} $if ($call lt (i, 0)) null ($call nth_or_null ($call vl.val (v.items), i)),
  $case v null
)

// An array's elements, an object's keys and its values; empty for anything else.
$decl items $func ($decl v value) $match v (
  $case {$prop tag "arr"} $call vl.val (v.items),
  $case v values.nil
)
$decl keys $func ($decl v value) $match v (
  $case {$prop tag "obj"} $call cl.val (v.keys),
  $case v strs.nil
)
$decl vals $func ($decl v value) $match v (
  $case {$prop tag "obj"} $call vl.val (v.vals),
  $case v values.nil
)
// How many elements or members; 0 for anything else.
$decl length $func ($decl v value) $match v (
  $case {$prop tag "arr"} $call vl.length (v.items, 0),
  $case {$prop tag "obj"} $call cl.length (v.keys, 0),
  $case v 0
)

$decl str_or $func ($decl v value, $decl d "") $match v ($case {$prop tag "str"} v.v, $case v d)
$decl bool_or $func ($decl v value, $decl d C.bool) $match v (
  $case {$prop tag "bool"} v.v,
  $case v d
)
// A number written as an integer, or `d` — for one with a fraction or an exponent too.
$decl int_or $func ($decl v value, $decl d 0) $match v (
  $case {$prop tag "num"} $call C.or_else ($call str_to_int (v.text), d),
  $case v d
)

// ----------------------------------------------------------------- writing

$decl builder $call S.builder ()

$decl hex_digits "0123456789abcdef"
$decl hex_at $func ($decl n 0) $call slice (hex_digits, n, $call add (n, 1))

// The escape for byte `c` inside a JSON string, or "" when it stands for itself. A byte of
// a multi-byte code point is 128 or more and stands for itself.
$decl escape_of $func ($decl c 0)
  $if ($call eq (c, 34)) "\\\""
  ($if ($call eq (c, 92)) "\\\\"
  ($if ($call eq (c, 10)) "\\n"
  ($if ($call eq (c, 13)) "\\r"
  ($if ($call eq (c, 9)) "\\t"
  ($if ($call lt (c, 32))
       ($call concat ("\\u00", $call concat ($call hex_at ($call div (c, 16)),
                                             $call hex_at ($call mod (c, 16)))))
       "")))))

// A run that needs no escape is written in one piece.
$decl quote_go $func ($decl b builder, $decl s "", $decl start 0, $decl i 0)
  $if ($call lt (i, $call len (s)))
      ($if ($call eq ($call len ($call escape_of ($call byte (s, i))), 0))
           ($call quote_go (b, s, start, $call add (i, 1)))
           ($do ($call b.write ($call slice (s, start, i)))
                ($do ($call b.write ($call escape_of ($call byte (s, i))))
                     ($call quote_go (b, s, $call add (i, 1), $call add (i, 1))))))
      ($call b.write ($call slice (s, start, i)))
$decl quote $func ($decl b builder, $decl s "")
  $do ($call b.write ("\"")) ($do ($call quote_go (b, s, 0, 0)) ($call b.write ("\"")))

$fwd write
$decl write_items $func ($decl b builder, $decl xs values.node, $decl first C.bool) $match xs (
  $case {$prop tag "cons"}
    $do ($if first () ($call b.write (",")))
        ($do ($call write (b, xs.head)) ($call write_items (b, xs.tail, false))),
  $case xs ()
)
$decl write_members $func ($decl b builder, $decl ks strs.node, $decl vs values.node,
                           $decl first C.bool) $match ks (
  $case {$prop tag "cons"}
    $do ($if first () ($call b.write (",")))
        ($do ($call quote (b, ks.head))
             ($do ($call b.write (":"))
                  ($do ($call write (b, $call vl.head (vs)))
                       ($call write_members (b, $call cl.val (ks.tail), $call vl.rest (vs),
                                             false))))),
  $case ks ()
)
// `v` as JSON text, with no space between tokens.
$decl write $func ($decl b builder, $decl v value) $match v (
  $case {$prop tag "null"} $call b.write ("null"),
  $case {$prop tag "bool"} $call b.write ($if v.v "true" "false"),
  $case {$prop tag "num"}  $call b.write (v.text),
  $case {$prop tag "str"}  $call quote (b, v.v),
  $case {$prop tag "arr"}
    $do ($call b.write ("["))
        ($do ($call write_items (b, $call vl.val (v.items), true)) ($call b.write ("]"))),
  $case v
    $do ($call b.write ("{"))
        ($do ($call write_members (b, $call keys (v), $call vals (v), true)) ($call b.write ("}")))
)
$decl text $func ($decl v value) {
  $decl b   $call S.builder ()
  $decl w   $call write (b, v)
  $decl ret $call b.build ()
}.ret

// ----------------------------------------------------------------- parsing

// A value read and the byte after it, or what was wrong and where — each at the one type
// every reader below answers. A string read answers the same shape at `Str`.
$decl failed $func ($decl m "", $decl i 0) { $prop tag "err"  $decl msg m  $decl pos i }
$decl got    $func ($decl x value, $decl i 0) { $prop tag "ok"  $decl v x  $decl pos i }
$decl ok_at  $func ($decl x value, $decl i 0) $union ($call got (x, i), $call failed ("", 0))
$decl err_at $func ($decl m "", $decl i 0) $union ($call failed (m, i), $call got (null, 0))
$decl sgot   $func ($decl s "", $decl i 0) { $prop tag "ok"  $decl v s  $decl pos i }
$decl s_ok   $func ($decl s "", $decl i 0) $union ($call sgot (s, i), $call failed ("", 0))
$decl s_err  $func ($decl m "", $decl i 0) $union ($call failed (m, i), $call sgot ("", 0))
// A read whose type is not known yet — `read_value`'s, while the group is solved — at the
// type it will have.
$decl as_read $func ($decl r ($call ok_at (null, 0))) r

// The byte at `i`, or -1 past the end, so a test never has to guard.
$decl at_b $func ($decl s "", $decl i 0)
  $if ($call lt (i, $call len (s))) ($call byte (s, i)) -1

$decl is_ws $func ($decl c 0)
  $call C.or ($call C.or ($call eq (c, 32), $call eq (c, 10)),
              $call C.or ($call eq (c, 13), $call eq (c, 9)))
$decl ws $func ($decl s "", $decl i 0)
  $if ($call is_ws ($call at_b (s, i))) ($call ws (s, $call add (i, 1))) i

$decl is_digit $func ($decl c 0) $call C.and ($call lt (47, c), $call lt (c, 58))
$decl digits $func ($decl s "", $decl i 0)
  $if ($call is_digit ($call at_b (s, i))) ($call digits (s, $call add (i, 1))) i

// A hex digit's value, or -1.
$decl hex_val $func ($decl c 0)
  $if ($call is_digit (c)) ($call sub (c, 48))
  ($if ($call C.and ($call lt (96, c), $call lt (c, 103))) ($call sub (c, 87))
  ($if ($call C.and ($call lt (64, c), $call lt (c, 71))) ($call sub (c, 55)) -1))
// The four hex digits at `i` as a number, or -1.
$decl hex4 $func ($decl s "", $decl i 0, $decl k 0, $decl acc 0)
  $if ($call eq (k, 4)) acc {
    $decl h    $call hex_val ($call at_b (s, $call add (i, k)))
    $decl ret2 $if ($call lt (h, 0)) -1
                   ($call hex4 (s, i, $call add (k, 1), $call add ($call mul (acc, 16), h)))
  }.ret2

// The text of code point `c`, or "" for one that is not (a lone surrogate).
$decl code_text $func ($decl c 0) $call C.or_else ($call from_code (c), "")

// `\u` at `i` (the backslash): its code point, joined with a following low surrogate, and
// the byte after it all — or -1 for the code point when it is malformed.
$decl unicode $func ($decl s "", $decl i 0) {
  $decl hi   $call hex4 (s, $call add (i, 2), 0, 0)
  $decl lead $call C.and ($call lt (55295, hi), $call lt (hi, 56320))
  $decl pair $if lead ($call C.and ($call eq ($call at_b (s, $call add (i, 6)), 92),
                                    $call eq ($call at_b (s, $call add (i, 7)), 117))) false
  $decl lo   $if pair ($call hex4 (s, $call add (i, 8), 0, 0)) -1
  $decl low  $call C.and ($call lt (56319, lo), $call lt (lo, 57344))
  $decl ret  $if low
      { $decl code $call add (65536, $call add ($call mul ($call sub (hi, 55296), 1024),
                                                $call sub (lo, 56320)))
        $decl next $call add (i, 12) }
      { $decl code hi  $decl next $call add (i, 6) }
}.ret

// The text of a one-character escape's letter `c`, or "".
$decl simple_escape $func ($decl c 0)
  $if ($call eq (c, 34)) "\""
  ($if ($call eq (c, 92)) "\\"
  ($if ($call eq (c, 47)) "/"
  ($if ($call eq (c, 98)) "\u{8}"
  ($if ($call eq (c, 102)) "\u{c}"
  ($if ($call eq (c, 110)) "\n"
  ($if ($call eq (c, 114)) "\u{d}"
  ($if ($call eq (c, 116)) "\t" "")))))))

// The escape at `i`, when the byte there is a backslash: the text it stands for ("" when it
// is malformed) and the byte after it.
$decl esc_of $func ($decl s "", $decl i 0)
  $if ($call eq ($call at_b (s, i), 92)) {
    $decl e    $call at_b (s, $call add (i, 1))
    $decl t    $call simple_escape (e)
    $decl u    $if ($call eq (e, 117)) ($call unicode (s, i)) { $decl code -1  $decl next i }
    $decl ret2 $if ($call lt (0, $call len (t))) { $decl text t  $decl next $call add (i, 2) }
      ($if ($call lt (u.code, 0)) { $decl text ""  $decl next i }
           { $decl text $call code_text (u.code)  $decl next u.next })
  }.ret2 { $decl text ""  $decl next i }

// A string's contents from `i`, the byte after its opening quote; `start` begins the run not
// yet written to `b`. `c` is the byte at `i` and `e` the escape there, passed in so that the
// loop is one tail call (§7.7) — a string is as long as a document.
$decl chars $func ($decl s "", $decl i 0, $decl start 0, $decl b builder, $decl c 0,
                   $decl e ($call esc_of ("", 0)))
  $if ($call lt (c, 0)) ($call s_err ("unterminated string", i))
  ($if ($call eq (c, 34))
       ($do ($call b.write ($call slice (s, start, i)))
            ($call s_ok ($call b.build (), $call add (i, 1))))
  ($if ($call eq (c, 92))
       ($if ($call eq ($call len (e.text), 0)) ($call s_err ("invalid escape in string", i))
            ($do ($call b.write ($call slice (s, start, i)))
                 ($do ($call b.write (e.text))
                      ($call chars (s, e.next, e.next, b, $call at_b (s, e.next),
                                    $call esc_of (s, e.next))))))
  ($if ($call lt (c, 32)) ($call s_err ("control character in string", i))
       ($call chars (s, $call add (i, 1), start, b, $call at_b (s, $call add (i, 1)),
                     $call esc_of (s, $call add (i, 1)))))))
$decl read_string $func ($decl s "", $decl i 0)
  $call chars (s, i, i, $call S.builder (), $call at_b (s, i), $call esc_of (s, i))

// A number's text from `i`, checked against JSON's grammar: an optional `-`, `0` or digits
// not starting with `0`, then an optional fraction and exponent.
$decl read_num $func ($decl s "", $decl i 0) {
  $decl j    $if ($call eq ($call at_b (s, i), 45)) ($call add (i, 1)) i
  $decl c    $call at_b (s, j)
  $decl k    $if ($call eq (c, 48)) ($call add (j, 1)) ($call digits (s, j))
  $decl f    $if ($call eq ($call at_b (s, k), 46)) ($call digits (s, $call add (k, 1))) k
  $decl ef   $call C.or ($call eq ($call at_b (s, f), 101), $call eq ($call at_b (s, f), 69))
  $decl sg   $if ef ($call add (f, 1)) f
  $decl p    $if ($call C.or ($call eq ($call at_b (s, sg), 43), $call eq ($call at_b (s, sg), 45)))
                 ($call add (sg, 1)) sg
  $decl e    $if ef ($call digits (s, p)) f
  $decl ret2 $if ($call eq (k, j)) ($call err_at ("expected a digit", j))
    ($if ($call eq (f, $call add (k, 1))) ($call err_at ("expected a digit after '.'", f))
    ($if ($call C.and (ef, $call eq (e, p))) ($call err_at ("expected a digit in the exponent", p))
         ($call ok_at ($call jv ({ $prop tag "num"  $decl text $call slice (s, i, e) }), e))))
}.ret2

// `word` at `i`, read as `v`.
$decl read_word $func ($decl s "", $decl i 0, $decl word "", $decl v value) {
  $decl e    $call add (i, $call len (word))
  $decl ret2 $if ($call lt ($call len (s), e)) ($call err_at ("unexpected character", i))
      ($if ($call eq_str ($call slice (s, i, e), word)) ($call ok_at (v, e))
           ($call err_at ("unexpected character", i)))
}.ret2

$fwd read_value

// An array's elements from `i`, and an object's members: each step a tail call, so a long
// array is a loop (§7.7). What `read_value` reads is passed to the step that looks at it.
$fwd read_items
$decl items_sep $func ($decl s "", $decl k 0, $decl xs values.node)
  $if ($call eq ($call at_b (s, k), 44)) ($call read_items (s, $call add (k, 1), xs))
  ($if ($call eq ($call at_b (s, k), 93))
       ($call ok_at ($call arr ($call vl.reverse (xs, values.nil)), $call add (k, 1)))
       ($call err_at ("expected ',' or ']'", k)))
$decl items_after $func ($decl s "", $decl r ($call ok_at (null, 0)), $decl acc values.node)
  $match r (
  $case {$prop tag "ok"}  $call items_sep (s, $call ws (s, r.pos), $call vl.cons (r.v, acc)),
  $case {$prop tag "err"} $call err_at (r.msg, r.pos)
)
$decl read_items $func ($decl s "", $decl i 0, $decl acc values.node)
  $call items_after (s, $call as_read ($call read_value (s, i)), acc)
$decl read_arr $func ($decl s "", $decl i 0) {
  $decl j    $call ws (s, i)
  $decl ret2 $if ($call eq ($call at_b (s, j), 93))
                 ($call ok_at ($call arr (values.nil), $call add (j, 1)))
                 ($call read_items (s, j, values.nil))
}.ret2

$fwd read_members
$decl members_sep $func ($decl s "", $decl m 0, $decl ks strs.node, $decl vs values.node)
  $if ($call eq ($call at_b (s, m), 44)) ($call read_members (s, $call add (m, 1), ks, vs))
  ($if ($call eq ($call at_b (s, m), 125))
       ($call ok_at ($call obj ($call cl.reverse (ks, strs.nil), $call vl.reverse (vs, values.nil)),
                     $call add (m, 1)))
       ($call err_at ("expected ',' or '}'", m)))
$decl members_after $func ($decl s "", $decl r ($call ok_at (null, 0)), $decl ks strs.node,
                           $decl vs values.node) $match r (
  $case {$prop tag "ok"}  $call members_sep (s, $call ws (s, r.pos), ks, $call vl.cons (r.v, vs)),
  $case {$prop tag "err"} $call err_at (r.msg, r.pos)
)
$decl members_value $func ($decl s "", $decl k 0, $decl key "", $decl ks strs.node,
                           $decl vs values.node)
  $if ($call eq ($call at_b (s, k), 58))
      ($call members_after (s, $call as_read ($call read_value (s, $call add (k, 1))),
                            $call cl.cons (key, ks), vs))
      ($call err_at ("expected ':'", k))
$decl members_key $func ($decl s "", $decl key ($call s_ok ("", 0)), $decl ks strs.node,
                         $decl vs values.node) $match key (
  $case {$prop tag "ok"}  $call members_value (s, $call ws (s, key.pos), key.v, ks, vs),
  $case {$prop tag "err"} $call err_at (key.msg, key.pos)
)
$decl read_members $func ($decl s "", $decl i 0, $decl ks strs.node, $decl vs values.node) {
  $decl j    $call ws (s, i)
  $decl ret2 $if ($call eq ($call at_b (s, j), 34)) ($call members_key (s, $call read_string (s,
                 $call add (j, 1)), ks, vs))
                 ($call err_at ("expected a string", j))
}.ret2
$decl read_obj $func ($decl s "", $decl i 0) {
  $decl j    $call ws (s, i)
  $decl ret2 $if ($call eq ($call at_b (s, j), 125))
                 ($call ok_at ($call obj (strs.nil, values.nil), $call add (j, 1)))
                 ($call read_members (s, j, strs.nil, values.nil))
}.ret2

$decl read_value $func ($decl s "", $decl i 0) {
  $decl j    $call ws (s, i)
  $decl c    $call at_b (s, j)
  $decl ret2 $if ($call lt (c, 0)) ($call err_at ("unexpected end of input", j))
    ($if ($call eq (c, 123)) ($call read_obj (s, $call add (j, 1)))
    ($if ($call eq (c, 91)) ($call read_arr (s, $call add (j, 1)))
    ($if ($call eq (c, 34)) {
        $decl r    $try ($call read_string (s, $call add (j, 1))) err
        $decl ret3 $call ok_at ($call str (r.v), r.pos)
      }.ret3
    ($if ($call eq (c, 116)) ($call read_word (s, j, "true", $call boolean (true)))
    ($if ($call eq (c, 102)) ($call read_word (s, j, "false", $call boolean (false)))
    ($if ($call eq (c, 110)) ($call read_word (s, j, "null", null))
    ($if ($call C.or ($call eq (c, 45), $call is_digit (c))) ($call read_num (s, j))
         ($call err_at ("unexpected character", j)))))))))
}.ret2

// The value `s` holds — `{tag ok, v, pos}`, `pos` its length — or `{tag err, msg, pos}`.
$decl parse $func ($decl s "") {
  $decl r    $try ($call as_read ($call read_value (s, 0))) err
  $decl k    $call ws (s, r.pos)
  $decl ret2 $if ($call lt (k, $call len (s))) ($call err_at ("unexpected text after the value", k))
                 ($call ok_at (r.v, k))
}.ret2
