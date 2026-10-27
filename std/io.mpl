// std/io: the platform group (§8) in the shapes a program wants — lines, whole files,
// the argument list — over `print`, `eprint`, `read_file`, `write_file` and `args`; and
// streams — `stdin`, `stdout`, `stderr`, readers and writers in memory, and the helpers
// that take any of them (see "streams" below). A failure that is expected is a value
// (§4.15): reading a file answers an option, writing one `ok` or `err`.

$decl C $import "std/core"
$decl L $import "std/list"
$decl S $import "std/str"

$decl strs $specialize L.list ""

$decl print_line  $func ($decl s "") $do ($call print (s)) ($call print ("\n"))
$decl eprint_line $func ($decl s "") $do ($call eprint (s)) ($call eprint ("\n"))

// A whole file, or `none` when it cannot be read or is not UTF-8 (§3.1); and a whole file
// written, truncating, answering `ok` or `err`.
$decl read  $func ($decl path "") $call read_file (path)
$decl write $func ($decl path "", $decl text "") $call write_file (path, text)

// The text between newlines. A final newline ends the last line rather than starting an
// empty one, so `lines` and `unlines` are inverses on text that ends in one; a `\r` before
// a newline is kept, since what it means is the file's business.
$decl c_nl $call byte ("\n", 0)
$decl cl   strs.cell
$decl lines_go $func ($decl s "", $decl i 0, $decl start 0, $decl acc strs.node)
  $if ($call lt (i, $call len (s)))
      ($if ($call eq ($call byte (s, i), c_nl))
           ($call lines_go (s, $call add (i, 1), $call add (i, 1),
                $call cl.cons ($call slice (s, start, i), acc)))
           ($call lines_go (s, $call add (i, 1), start, acc)))
      ($call cl.reverse ($if ($call lt (start, i))
           ($call cl.cons ($call slice (s, start, i), acc)) acc, strs.nil))
$decl lines $func ($decl s "") $call strs.of ($call lines_go (s, 0, 0, strs.nil))

// Each line followed by a newline, joined pairwise by `std/str` (D6).
$decl unlines $func ($decl xs ($call strs.empty ()))
  $if ($call xs.is_empty ()) "" ($call concat ($call S.join (xs, "\n"), "\n"))

$decl read_lines  $func ($decl path "") $call C.map_opt ($call read_file (path), lines)
$decl write_lines $func ($decl path "", $decl xs ($call strs.empty ()))
  $call write_file (path, $call unlines (xs))

// §8's `args ()` — the program's arguments, without its name — as a list.
$decl arg_list $func () $call strs.from_array ($call args ())

// ------------------------------------------------------------------- streams
//
// A writer is anything with `write (s)` and `flush ()`, a reader anything with `read (max)`
// (§6: structural, so a socket or a counting wrapper of a user's own is one too). The
// helpers below are bounded templates, so a call on a stream whose type is known is static
// and passes the stream as itself; a stream chosen at run time is made a `writer` or a
// `reader` with `as_writer` / `as_reader`, a trait object, and the same helpers take that.
//
//   $call I.write_line (I.stdout, "hello")
//   $decl out $if quiet ($call I.as_writer (log)) ($call I.as_writer (I.stderr))
//   $call I.write_line (out, "hello")
//
// Every stream is allocated storage (§4.2a), `stdout` included, because a trait object
// refers to its value and §5.3a keeps one over frame storage out of a field, a tail call
// and anything `$alloc`ed — so a `writer` of one of these can go in a list. Make a stream of
// your own the same way, `$alloc $call I.from_str (…)`.
//
// A failure is `{tag err, e <errno>}` — §5.1 keeps it an `err`, so `$try … err` hands it up —
// and `describe` is its text. Success is `ok` for a write; a read answers
// `{tag ok, v <text>}`, at least one code point unless the stream has ended, where it is
// `""`. `max` is in bytes and at least 4, so that one code point always fits (§3.1).

// What `$extern` reaches, as C declares it (§4.16). Linux's errno is a thread's `int`, read
// by copying its four bytes into the low end of an `Int` cell, which assumes little endian.
$decl c_read     $extern "ssize_t read(int, void *, size_t)"
  $func ($decl fd 0, $decl p 0, $decl n 0) 0
$decl c_memmove  $extern "void *memmove(void *, const void *, size_t)"
  $func ($decl d 0, $decl s 0, $decl n 0) 0
$decl c_memcpy   $extern "void *memcpy(void *, const void *, size_t)"
  $func ($decl d 0, $decl s 0, $decl n 0) 0
$decl c_errno    $extern "int *__errno_location(void)"
  $func () 0
$decl c_strerror $extern "char *strerror(int)"
  $func ($decl e 0) 0
$decl c_strlen   $extern "size_t strlen(const char *)"
  $func ($decl s 0) 0
$decl c_fflush   $extern "int fflush(FILE *)"
  $func ($decl f 0) 0

$decl e_intr  4
$decl e_ilseq 84

$decl errno $func () {
  $decl cell $mut $alloc 0
  $decl w    $call c_memcpy ($call box_ptr (cell), $call c_errno (), 4)
  $decl ret  $call C.ival (cell)
}.ret

// The text of an error code, as `strerror` gives it.
$decl describe $func ($decl e 0) {
  $decl p   $call c_strerror (e)
  $decl ret $call C.or_else ($call str_from_ptr (p, $call c_strlen (p)), "unknown error")
}.ret

// The answers, each at the type its method is declared with: `wrote` and `write_failed`
// for a write or a flush, `got` and `read_failed` for a read.
$decl fail         $func ($decl code 0) { $prop tag "err" $decl e code }
$decl chunk        $func ($decl s "") { $prop tag "ok" $decl v s }
$decl wrote        $union (C.ok, $call fail (0))
$decl write_failed $func ($decl code 0) $union ($call fail (code), C.ok)
$decl got          $func ($decl s "") $union ($call chunk (s), $call fail (0))
$decl read_failed  $func ($decl code 0) $union ($call fail (code), $call chunk (""))

$decl writer_proto {
  $prop write $func ($decl s "") wrote
  $prop flush $func () wrote
}
$decl reader_proto { $prop read $func ($decl max 0) $call got ("") }
$decl writer $traitsof writer_proto
$decl reader $traitsof reader_proto

$decl as_writer $func ($decl w writer) w
$decl as_reader $func ($decl r reader) r

// ------------------------------------------------------- the process's streams

// `stdout` and `stderr` go through C's stdio, as `print` and `eprint` do, so the two
// orders agree. stdio buffers, so a failed write is reported by the `flush` after it;
// `flush` flushes every stream (`fflush (NULL)`). §7.8's `panic` aborts without flushing.
$decl flushed $func ()
  $if ($call eq ($call c_fflush (0), 0)) wrote ($call write_failed ($call errno ()))
$decl stdout $alloc {
  $prop write $func ($decl s "") $do ($call print (s)) wrote
  $prop flush $func () $call flushed ()
}
$decl stderr $alloc {
  $prop write $func ($decl s "") $do ($call eprint (s)) wrote
  $prop flush $func () $call flushed ()
}

// A reader over file descriptor `fd`, through a buffer of `cap` bytes. A chunk is cut where a
// code point ends, carrying the rest to the next read; bytes that are not UTF-8 are
// `e_ilseq`'s failure, and so is a code point the stream ends in the middle of.
$decl fd_reader $func ($decl fd 0, $decl cap 4096) {
  $decl size $call C.max (cap, 4)
  $decl mem  $call raw_alloc (size)
  $decl ok   $if ($call eq (mem, 0)) ($call panic ("io: out of memory")) 0
  $decl r    {
    $decl file  fd
    $decl buf   mem
    $decl room  size
    $decl have  $mut $alloc 0
    $prop read  $func ($decl max 0) $call r.next ($call C.max (4, $call C.min (max, r.room)))
    // The longest of the first `k`, `k - 1` … `k - 3` bytes that is text, or `none`.
    $prop take  $func ($decl k 0, $decl j 0)
      $if ($call C.or ($call eq (j, 4), $call lt ($call sub (k, j), 1))) none {
        $decl o    $call str_from_ptr (r.buf, $call sub (k, j))
        $decl ret2 $match o ($case {$prop tag "some"} o, $case o $call r.take (k, $call add (j, 1)))
      }.ret2
    $prop next  $func ($decl m 0) {
      $decl h    $call C.ival (r.have)
      $decl t    $if ($call eq (h, 0)) none ($call r.take ($call C.min (h, m), 0))
      $decl ret2 $match t (
        $case {$prop tag "some"} $call r.emit (t.v, h),
        $case t $if ($call lt (3, $call C.min (h, m))) ($call read_failed (e_ilseq))
                    ($call r.fill (m, h)))
    }.ret2
    // The first `len (s)` bytes, decoded as `s`, handed out and the rest moved up.
    $prop emit  $func ($decl s "", $decl h 0) {
      $decl k    $call len (s)
      $decl mv   $call c_memmove (r.buf, $call add (r.buf, k), $call sub (h, k))
      $decl w    $set r.have ($call sub (h, k))
      $decl ret2 $call got (s)
    }.ret2
    $prop fill  $func ($decl m 0, $decl h 0) {
      $decl n    $call c_read (r.file, $call add (r.buf, h), $call sub (r.room, h))
      $decl e    $if ($call lt (n, 0)) ($call errno ()) 0
      $decl ret2 $if ($call lt (n, 0))
        ($if ($call eq (e, e_intr)) ($call r.fill (m, h)) ($call read_failed (e)))
        ($if ($call eq (n, 0))
             ($if ($call eq (h, 0)) ($call got ("")) ($call read_failed (e_ilseq)))
             ($do ($set r.have ($call add (h, n))) ($call r.next (m))))
    }.ret2
  }
  $decl ret  r
}.ret

$decl stdin $alloc $call fd_reader (0, 4096)

// ------------------------------------------------------------ in memory

// A reader over `s`, cutting where a code point ends.
$decl c_cont $func ($decl b 0) $call C.and ($call lt (127, b), $call lt (b, 192))
$decl from_str $func ($decl s "") {
  $decl r   {
    $decl text s
    $decl pos  $mut $alloc 0
    // The first index at or below `i` where a code point starts.
    $prop back $func ($decl i 0)
      $if ($call lt (i, $call len (r.text)))
          ($if ($call c_cont ($call byte (r.text, i))) ($call r.back ($call sub (i, 1))) i) i
    $prop read $func ($decl max 0) {
      $decl p    $call C.ival (r.pos)
      $decl k    $call C.min ($call C.max (max, 4), $call sub ($call len (r.text), p))
      $decl e    $call r.back ($call add (p, k))
      $decl w    $set r.pos e
      $decl ret2 $call got ($call slice (r.text, p, e))
    }.ret2
  }
  $decl ret r
}.ret

// A writer collecting what it is given; `text ()` is all of it.
$decl to_text $func () {
  $decl w   {
    $decl b    $call S.builder ()
    $prop write $func ($decl s "") $do ($call w.b.write (s)) wrote
    $prop flush $func () wrote
    $prop text  $func () $call w.b.build ()
  }
  $decl ret w
}.ret

// ------------------------------------------------------------- helpers

// `s` and a newline, or the failure of the first write.
$decl write_line $template ($decl W $traitsof writer_proto) $func ($decl w W, $decl s "") {
  $decl a   $try ($call w.write (s)) err
  $decl ret $call w.write ("\n")
}.ret

// Everything left in `r`, or the failure that stopped it. `builder` is an example for the
// parameter, evaluated once (§4.10) and never written to.
$decl builder $call S.builder ()
$decl read_rest $template ($decl R $traitsof reader_proto)
  $func ($decl r R, $decl b builder, $decl c ($call got (""))) $match c (
    $case {$prop tag "ok"}
      $if ($call eq (c.v, "")) ($call got ($call b.build ()))
          ($do ($call b.write (c.v)) ($call read_rest (r, b, $call r.read (4096)))),
    $case c c)
$decl read_all $template ($decl R $traitsof reader_proto) $func ($decl r R)
  $call read_rest (r, $call S.builder (), $call r.read (4096))

// Everything in `r` written to `w`, then `ok`; or the first failure of either. `x` is the
// last write's answer and `c` the chunk after it — §7.1 evaluates arguments in order, so the
// write is done before the next read — which keeps the loop one tail call.
$decl copy_rest $template ($decl R $traitsof reader_proto, $decl W $traitsof writer_proto)
  $func ($decl r R, $decl w W, $decl x wrote, $decl c ($call got (""))) $match x (
    $case C.ok $match c (
      $case {$prop tag "ok"}
        $if ($call eq (c.v, "")) wrote
            ($call copy_rest (r, w, $call w.write (c.v), $call r.read (4096))),
      $case c $call write_failed (c.e)),
    $case x x)
$decl copy $template ($decl R $traitsof reader_proto, $decl W $traitsof writer_proto)
  $func ($decl r R, $decl w W) $call copy_rest (r, w, wrote, $call r.read (4096))
