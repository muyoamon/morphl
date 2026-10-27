// std/io's tests: `mplc std/io_test.mpl -L . -o …` from the repository root, run with no
// arguments. A failure is reported on stderr and aborts; `main` answers how many passed.

$decl C $import "std/core"
$decl L $import "std/list"
$decl I $import "std/io"
$decl T $import "std/test"

$decl strs $specialize L.list ""
$decl ws   $specialize L.list I.writer

// A test opens its own file: `std/io` has no file streams yet.
$decl c_open $extern "int open(const char *, int)" $func ($decl p 0, $decl f 0) 0

$decl tmp "/tmp/morphl_std_io_test.txt"

// `n` lines of `x`, for a join big enough that appending would show.
$decl many $func ($decl n 0, $decl acc ($call strs.empty ()))
  $if ($call lt (0, n)) ($call many ($call sub (n, 1), $call acc.push ("x"))) acc

// The text of a read, or `ERR`.
$decl text_of $func ($decl c ($call I.got ("")))
  $match c ($case {$prop tag "ok"} c.v, $case c "ERR")
$decl is_ok $func ($decl x I.wrote) $match x ($case C.ok true, $case x false)

// One helper, on a stream whose type is known and on a `writer` chosen at run time.
$decl pick $func ($decl first C.bool, $decl a I.writer, $decl b I.writer) $if first a b

// Each writer in a list given `s`.
$decl each $func ($decl xs ws.node, $decl s "") $match xs (
  $case {$prop tag "cons"}
    $do ($call I.write_line (xs.head, s)) ($call each ($call ws.cell.val (xs.tail), s)),
  $case xs ())

$decl uni "héllo wörld — ∑ 𝄞\n"

$decl main $func () {
  $decl r   $call T.results ()
  $decl ls  $call I.lines ("one\ntwo\n\nfour")
  $decl c1  $call T.expect (r, "lines splits on newlines", $call eq ($call ls.length (), 4))
  $decl c2  $call T.expect (r, "...keeping an empty line", $call eq ($call ls.nth (2), ""))
  $decl c3  $call T.expect (r, "...and the last without a newline",
                $call eq ($call ls.nth (3), "four"))
  $decl c4  $call T.expect (r, "a final newline ends a line",
                $call eq ($call ($call I.lines ("a\nb\n")).length (), 2))
  $decl c5  $call T.expect (r, "no text is no lines", $call ($call I.lines ("")).is_empty ())
  $decl c6  $call T.expect (r, "unlines inverts lines",
                $call eq ($call I.unlines ($call I.lines ("a\nb\n")), "a\nb\n"))
  $decl big $call I.unlines ($call many (5000, $call strs.empty ()))
  $decl c7  $call T.expect (r, "unlines joins many", $call eq ($call len (big), 10000))
  $decl w   $call I.write_lines (tmp, $call I.lines ("alpha\nbeta\n"))
  $decl c8  $call T.expect (r, "write_lines writes", $match w ($case C.ok true, $case err false))
  $decl back $call C.or_else ($call I.read_lines (tmp), $call strs.empty ())
  $decl c9  $call T.expect (r, "read_lines reads them back", $call eq ($call back.nth (1), "beta"))
  $decl c10 $call T.expect (r, "read of a missing file is none",
                $call C.is_none ($call I.read ("/nonexistent/morphl/file")))
  $decl c11 $call T.expect (r, "arg_list is empty with no arguments",
                $call ($call I.arg_list ()).is_empty ())
  $decl m   $alloc $call I.to_text ()
  $decl n   $alloc $call I.to_text ()
  $decl x1  $call I.write_line (m, "one")
  $decl x2  $call I.write_line ($call pick ($call eq ($call len ("ab"), 2), $call I.as_writer (n),
                $call I.as_writer (m)), "two")
  $decl c12 $call T.expect (r, "write_line on a stream", $call eq ($call m.text (), "one\n"))
  $decl c13 $call T.expect (r, "...and on a writer chosen at run time",
                $call eq ($call n.text (), "two\n"))
  $decl x3  $call each ($call ws.cell.cons ($call I.as_writer (m),
                $call ws.cell.cons ($call I.as_writer (n), ws.nil)), "all")
  $decl c14 $call T.expect (r, "writers in a list",
                $call C.and ($call eq ($call m.text (), "one\nall\n"),
                             $call eq ($call n.text (), "two\nall\n")))
  $decl fr  $alloc $call I.from_str ("aéé")
  $decl c15 $call T.expect (r, "a read is cut where a code point ends",
                $call eq ($call text_of ($call fr.read (4)), "aé"))
  $decl c16 $call T.expect (r, "...and the rest follows",
                $call eq ($call text_of ($call fr.read (4)), "é"))
  $decl c17 $call T.expect (r, "an ended stream reads empty",
                $call eq ($call text_of ($call fr.read (4)), ""))
  $decl ur  $alloc $call I.from_str (uni)
  $decl c18 $call T.expect (r, "read_all", $call eq ($call text_of ($call I.read_all (ur)), uni))
  $decl cr  $alloc $call I.from_str (uni)
  $decl co  $alloc $call I.to_text ()
  $decl cp  $call I.copy (cr, co)
  $decl c19 $call T.expect (r, "copy", $call C.and ($call is_ok (cp), $call eq ($call co.text (), uni)))
  $decl fw  $call write_file (tmp, uni)
  $decl fd  $call c_open ($call str_ptr ($call concat (tmp, "\u{0}")), 0)
  // Five bytes at a time, so code points straddle reads.
  $decl fdr $alloc $call I.fd_reader (fd, 5)
  $decl c20 $call T.expect (r, "a file descriptor through a small buffer",
                $call eq ($call text_of ($call I.read_all (fdr)), uni))
  $decl bad $alloc $call I.fd_reader (-1)
  $decl br  $call bad.read (16)
  $decl c21 $call T.expect (r, "a failed read answers errno",
                $match br ($case {$prop tag "err"} $call eq (br.e, 9), $case br false))
  $decl c22 $call T.expect (r, "describe", $call eq ($call I.describe (9), "Bad file descriptor"))
  $decl c23 $call T.expect (r, "stdout flushes",
                $call C.and ($call is_ok ($call I.stdout.flush ()),
                             $call is_ok ($call ($call I.as_writer (I.stderr)).flush ())))
  $decl ret $call T.finish (r)
}.ret
