// A round-trip fixture for §3.1's `Str`: pointer + length, immutable, always
// valid UTF-8. Prints `hello, world! 9 a`.
//
// `tricky` holds a quote, a backslash, a newline and a two-byte UTF-8 code
// point — so its length is 9 bytes, not 7 characters, and the C literal it
// emits has to survive all four.
$decl greet $func ($decl who "") $call concat ("hello, ", $call concat (who, "!"))

$decl tricky "a\"b\\c\nd\u{00e9}"

$decl main $func ()
  $call concat ($call greet ("world"),
  $call concat (" ", $call concat ($call int_to_str ($call len (tricky)),
  $call concat (" ", $call concat ($call slice (tricky, 0, 1), "\n")))))
