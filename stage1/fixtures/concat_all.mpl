// §8's `concat_all (parts)`: the pieces of a `[Str]` in order, in one allocation of their total
// length (STRINGS.md). Prints `[] [one] [a,b,c] [ü€😀] [xy] 3000000 abc|abc 6 a-b-c`:
//   []         an empty array is "";
//   [one]      one piece is itself;
//   [a,b,c]    several, in order, separators among them;
//   [ü€😀]     multi-byte pieces, joined bytewise;
//   [xy]       empty pieces contribute nothing;
//   3000000    a million three-byte pieces, and its first and last;
//   6          `concat_all` as a value, through an alias;
//   a-b-c      and passed to a function taking one.

$decl fill $func ($decl a $call array (0, ""), $decl i 0, $decl s "")
  $if ($call lt (i, $call alen (a)))
      ($do ($set ($call at (a, i)) s) ($call fill (a, $call add (i, 1), s)))
      a

$decl of $func ($decl x "", $decl y "", $decl z "") {
  $decl a   $call array (3, "")
  $decl w   $do ($set ($call at (a, 0)) x) ($do ($set ($call at (a, 1)) y)
                ($set ($call at (a, 2)) z))
  $decl ret a
}.ret

$decl box $func ($decl s "") $call concat ("[", $call concat (s, "]"))

$decl join_with $func ($decl j concat_all, $decl x "", $decl y "", $decl z "")
  $call j ($call of (x, y, z))

$decl main $func () {
  $decl e   $call concat_all ($call array (0, ""))
  $decl one $call concat_all ($call fill ($call array (1, ""), 0, "one"))
  $decl abc $call concat_all ($call of ("a,", "b,", "c"))
  $decl mb  $call concat_all ($call of ("ü", "€", "😀"))
  $decl emp $call concat_all ($call of ("", "xy", ""))
  $decl big $call concat_all ($call fill ($call array (1000000, ""), 0, "abc"))
  $decl ca  concat_all
  $decl via $call ca ($call of ("ab", "cd", "ef"))
  $decl hof $call join_with (concat_all, "a-", "b-", "c")
  $decl ret $call concat ($call box (e), $call concat (" ", $call concat ($call box (one),
                $call concat (" ", $call concat ($call box (abc), $call concat (" ",
                $call concat ($call box (mb), $call concat (" ", $call concat ($call box (emp),
                $call concat (" ", $call concat ($call int_to_str ($call len (big)),
                $call concat (" ", $call concat ($call slice (big, 0, 3), $call concat ("|",
                $call concat ($call slice (big, 2999997, 3000000), $call concat (" ",
                $call concat ($call int_to_str ($call len (via)), $call concat (" ",
                hof))))))))))))))))))
}.ret
