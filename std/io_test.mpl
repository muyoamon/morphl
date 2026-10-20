// std/io's tests: `mplc std/io_test.mpl -L . -o …` from the repository root, run with no
// arguments. A failure is reported on stderr and aborts; `main` answers how many passed.

$decl C $import "std/core"
$decl L $import "std/list"
$decl I $import "std/io"
$decl T $import "std/test"

$decl strs $specialize L.list ""

$decl tmp "/tmp/morphl_std_io_test.txt"

// `n` lines of `x`, for a join big enough that appending would show.
$decl many $func ($decl n 0, $decl acc strs.node)
  $if ($call lt (0, n)) ($call many ($call sub (n, 1), $call strs.cons ("x", acc))) acc

$decl main $func () {
  $decl r   $call T.results ()
  $decl ls  $call I.lines ("one\ntwo\n\nfour")
  $decl c1  $call T.expect (r, "lines splits on newlines", $call eq ($call strs.length (ls, 0), 4))
  $decl c2  $call T.expect (r, "...keeping an empty line", $call eq ($call strs.nth (ls, 2), ""))
  $decl c3  $call T.expect (r, "...and the last without a newline",
                $call eq ($call strs.nth (ls, 3), "four"))
  $decl c4  $call T.expect (r, "a final newline ends a line",
                $call eq ($call strs.length ($call I.lines ("a\nb\n"), 0), 2))
  $decl c5  $call T.expect (r, "no text is no lines", $call strs.is_nil ($call I.lines ("")))
  $decl c6  $call T.expect (r, "unlines inverts lines",
                $call eq ($call I.unlines ($call I.lines ("a\nb\n")), "a\nb\n"))
  $decl big $call I.unlines ($call many (5000, strs.nil))
  $decl c7  $call T.expect (r, "unlines joins many", $call eq ($call len (big), 10000))
  $decl w   $call I.write_lines (tmp, $call I.lines ("alpha\nbeta\n"))
  $decl c8  $call T.expect (r, "write_lines writes", $match w ($case {$prop tag "err"} false, $case w true))
  $decl back $call C.or_else ($call I.read_lines (tmp), strs.node)
  $decl c9  $call T.expect (r, "read_lines reads them back", $call eq ($call strs.nth (back, 1), "beta"))
  $decl c10 $call T.expect (r, "read of a missing file is none",
                $call C.is_none ($call I.read ("/nonexistent/morphl/file")))
  $decl c11 $call T.expect (r, "arg_list is empty with no arguments",
                $call strs.is_nil ($call I.arg_list ()))
  $decl ret $call T.finish (r)
}.ret
