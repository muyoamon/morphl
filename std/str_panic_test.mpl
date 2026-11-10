// std/str's panics, one per run since each aborts: the case is the first argument, and
// `zig build test-std` checks the message and the abort. `clear` and `truncate` move a
// text's generation on, so a view made before reads as stale (TEXT.md, T6); a text is
// cut only where a code point starts (§3.1).

$decl S $import "std/str"

$decl stale_clear $func () {
  $decl t   $call S.text ()
  $decl w   $call t.write ("abc")
  $decl v   $call t.view ()
  $decl c   $call t.clear ()
  $decl ret $call S.len (v)
}.ret
$decl stale_truncate $func () {
  $decl t   $call S.text ()
  $decl w   $call t.write ("abc")
  $decl v   $call t.view ()
  $decl c   $call t.truncate (2)
  $decl w2  $call t.write ("!")
  $decl ret $call S.len ($call S.slice (v, 0, 1))
}.ret
$decl split_code $func () {
  $decl t   $call S.text ()
  $decl w   $call t.write ("aé")
  $decl c   $call t.truncate (2)
  $decl ret $call t.size ()
}.ret

$decl main $func () {
  $decl a   $call at ($call args (), 0)
  $decl ret $if ($call eq (a, "clear")) ($call stale_clear ())
      ($if ($call eq (a, "truncate")) ($call stale_truncate ())
           ($if ($call eq (a, "split")) ($call split_code ()) -1))
}.ret
