// P11's module half: a list whose value is a wrapper, with members that read their
// receiver, and a module member taking one as a parameter — so the member is reached
// through the parameter's type before anything builds the wrapper.
$decl list $template T {
  $prop nil    { $prop tag "nil" }
  $prop node   $union (nil, { $prop tag "cons"  $decl head T  $decl tail $alloc node })
  $prop c_nil  $func ($decl c node) $match c ($case {$prop tag "cons"} false, $case c true)
  $prop val    $func ($decl c node) c
  // `T` is `Str` wherever this is used, so the empty case answers "" rather than panic:
  // §7.8's result temporary would be set and never read, which `test-emit`'s -Werror sees.
  $prop c_head $func ($decl c node) $match c ($case {$prop tag "cons"} c.head, $case c "")
  $prop c_rest $func ($decl c node) $match c ($case {$prop tag "cons"} $call val (c.tail), $case c c)
  $prop of $func ($decl c node) {
    $decl w   {
      $decl cells c
      $prop is_empty $func () $call c_nil (w.cells)
      $prop head     $func () $call c_head (w.cells)
      $prop rest     $func () $call of ($call c_rest (w.cells))
      $prop push     $func ($decl x T)
        $call of ({ $prop tag "cons"  $decl head x  $decl tail $alloc w.cells })
    }
    $decl ret w
  }.ret
  $prop empty $func () $call of (nil)
}

$decl strs $specialize list ""

$decl total_len $func ($decl xs ($call strs.empty ()), $decl acc 0)
  $if ($call xs.is_empty ()) acc
      ($call total_len ($call xs.rest (), $call add (acc, $call len ($call xs.head ()))))
