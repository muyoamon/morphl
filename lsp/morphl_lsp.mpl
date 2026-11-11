// morphl-lsp: a language server for morphl over stdio (LSP 3.17), reporting diagnostics.
//
//   mplc lsp/morphl_lsp.mpl -L . -L stage1 -o zig-out/bin/morphl-lsp      (`zig build lsp`)
//
// The editor opens a document and the server checks it as it changes — parse and inference,
// §9.1's `parse` and `infer`, on the editor's text rather than the file's — and publishes what
// the checker says. `$import`s resolve as `mplc`'s do: beside the file, then each root, which
// are the workspace's root folder and `initializationOptions.roots` (relative to the root).
//
// **Each check is a process of its own.** The compiled runtime frees nothing a program does
// not `$free` (§7.6), and the checker's work is nearly all garbage, so a server that checked in
// its own process would grow by every check it ran. So the server is two programs in one
// binary: with `--check <buffer> <path> <out> [roots…]` it checks the text in `<buffer>` as if
// it were the file `<path>` and writes the diagnostics to `<out>` as JSON; with no arguments it
// is the server, which runs itself that way through §8's `run` — `/proc/self/exe`, so Linux —
// and reads the answer back. What the server itself keeps is the documents' latest text.
//
// A position is a line and a UTF-16 column (LSP's default encoding); the checker's columns are
// bytes, so each is converted against the document's text. A diagnostic carries a start and
// the server widens it to the token there. One raised in another file — an imported module,
// or a `$template`'s body checked where it is used (§10.7) — is shown at the top of the
// document, naming where it is.

$decl C  $import "compiler"
$decl Pa $import "parser"
$decl Co $import "std/core"
$decl F  $import "std/fmt"
$decl I  $import "std/io"
$decl J  $import "std/json"
$decl M  $import "std/map"
$decl S  $import "std/str"

$decl c_getpid $extern "int getpid(void)" $func () 0
$decl c_unlink $extern "int unlink(const char *)" $func ($decl p 0) 0
$decl c_exit   $extern "void exit(int)" $func ($decl code 0) ()
$decl c_getenv $extern "char *getenv(const char *)" $func ($decl name 0) 0

$decl argv   $call args ()
$decl nargv  $call alen (argv)
$decl arg_at $func ($decl i 0) $if ($call lt (i, nargv)) ($call Co.sval ($call at (argv, i))) ""

// ---------------------------------------------------------------- the checker

// The arguments from `i` on, as `C.parse`'s search roots.
$decl roots_from $func ($decl i 0, $decl acc Pa.pstrs.node)
  $if ($call lt (i, nargv))
      ($call roots_from ($call add (i, 1), $call Pa.pstrs.cons ($call arg_at (i), acc)))
      ($call Pa.pstrs.reverse (acc, Pa.pstrs.nil))

// A diagnostic as `{line, col, file, msg}`: `line` and `col` count from 1, `col` in bytes, and
// both are 0 for one with no position. A diagnostic with no file is the checked file's.
$decl diag_obj $func ($decl d ($call Pa.diag ("", 0, 0, "")), $decl path "") {
  $decl o   $call J.object ()
  $decl w1  $call o.put ("line", $call J.num (d.line))
  $decl w2  $call o.put ("col", $call J.num (d.col))
  $decl w3  $call o.put ("file", $call J.str ($if ($call eq_str (d.file, "")) path d.file))
  $decl w4  $call o.put ("msg", $call J.str (d.msg))
  $decl ret $call o.build ()
}.ret
$decl abuild $call J.array_of ()
$decl diags_json $func ($decl ds Pa.diags.node, $decl path "", $decl a abuild) $match ds (
  $case {$prop tag "cons"}
    $do ($call a.push ($call diag_obj (ds.head, path))) ($call diags_json (ds.tail, path, a)),
  $case ds ()
)

$decl check_mode $func () {
  $decl path $call arg_at (2)
  $decl src  $call Co.or_else ($call read_file ($call arg_at (1)), "")
  $decl t    $call C.infer ($call C.parse (src, path, $call roots_from (4, Pa.pstrs.nil)))
  $decl a    $call J.array_of ()
  $decl w    $call diags_json (t.diagnostics, path, a)
  $decl wr   $call write_file ($call arg_at (3), $call J.text ($call a.build ()))
  $decl ret  ()
}.ret

// ------------------------------------------------------------------ the state

$decl docs_t $specialize M.map ("", "")
$decl docs   $call docs_t.new (S.less)
$decl st {
  $decl down  $mut $alloc $union (false, true)
  $decl roots $mut $alloc Pa.pstrs.node
}

// Where a check's text and answer go, one pair per server: in `$XDG_RUNTIME_DIR`, which
// only its user can reach, since a name another user could guess and link elsewhere would
// have `write_file` write through the link; `/tmp` when it is not set.
$decl env_or $func ($decl name "", $decl d "") {
  $decl p   $call c_getenv ($call I.c_path (name))
  $decl ret $if ($call eq (p, 0)) d
                ($call Co.or_else ($call $primitives.str_from_ptr (p, $call I.c_strlen (p)), d))
}.ret
$decl tmp_dir $call env_or ("XDG_RUNTIME_DIR", "/tmp")
// `<dir>/morphl-lsp-<pid><ext>`.
$decl tmp_name $func ($decl ext "") {
  $decl t   $call S.text ()
  $decl w1  $call t.write (tmp_dir)
  $decl w2  $call t.write ("/morphl-lsp-")
  $decl w3  $call F.int (t, $call c_getpid ())
  $decl w4  $call t.write (ext)
  $decl ret $call S.copy_out ($call t.view ())
}.ret
$decl tmp_buf $call tmp_name (".mpl")
$decl tmp_out $call tmp_name (".json")

$decl unlink $func ($decl p "") $call c_unlink ($call I.c_path (p))

// ----------------------------------------------------------- reading messages
//
// A message is headers, a blank line and `Content-Length` bytes of JSON. The input is read
// into `carry`, and what is read past a message is kept there for the next one.

$decl carry $call S.text ()

$decl input $alloc $call I.fd_reader (0, 65536)

// More of the input added to `carry`; `false` at its end or a failure.
$decl more $func () {
  $decl ch  $call input.read (65536)
  $decl ret $match ch (
    $case {$prop tag "ok"}
      $if ($call eq_str (ch.v, "")) false ($do ($call carry.write (ch.v)) true),
    $case ch false)
}.ret

// Where the headers end (the blank line's offset), or -1 at the end of the input.
$decl read_head $func () {
  $decl f   $call S.find ($call carry.view (), "\u{d}\n\u{d}\n", 0)
  $decl ret $match f (
    $case {$prop tag "some"} f.v,
    $case f $if ($call more ()) ($call read_head ()) -1)
}.ret

// Whether `h` starts with `k` from byte `i`, an ASCII capital in `h` read as small, as header
// names are compared (RFC 9110); `k` is small already.
$decl small $func ($decl c 0)
  $if ($call Co.and ($call lt (64, c), $call lt (c, 91))) ($call add (c, 32)) c
$decl starts_nocase $func ($decl h "", $decl k "", $decl i 0)
  $if ($call lt (i, $call len (k)))
      ($if ($call lt (i, $call len (h)))
           ($if ($call eq ($call small ($call byte (h, i)), $call byte (k, i)))
                ($call starts_nocase (h, k, $call add (i, 1))) false)
           false)
      true

// The `Content-Length` among the header lines, or 0.
$decl length_of $func ($decl hs ($call S.split ("", "\n")).cells) $match hs (
  $case {$prop tag "cons"} {
    $decl h    $call S.trim (hs.head)
    $decl k    "content-length:"
    $decl ret2 $if ($call starts_nocase (h, k, 0))
                   ($call Co.or_else ($call str_to_int ($call S.trim ($call slice (h,
                       $call len (k), $call len (h)))), 0))
                   ($call length_of ($call S.cl.val (hs.tail)))
  }.ret2,
  $case hs 0
)

// The input read into `carry` until it holds `need` bytes; `false` if it ends first.
$decl fill $func ($decl need 0)
  $if ($call lt ($call carry.size (), need)) ($if ($call more ()) ($call fill (need)) false) true

// The next message's body, or `none` at the end of the input. The body and what follows it
// are copied out of `carry` before it is emptied for the rest.
$decl read_message $func () {
  $decl h   $call read_head ()
  $decl ret $if ($call lt (h, 0)) none {
    $decl hd   $call S.copy_out ($call S.slice ($call carry.view (), 0, h))
    $decl n    $call Co.max ($call length_of (($call S.split (hd, "\n")).cells), 0)
    $decl need $call add (h, $call add (4, n))
    $decl ret2 $if ($call fill (need)) {
        $decl v    $call carry.view ()
        $decl body $call S.copy_out ($call S.slice (v, $call add (h, 4), need))
        $decl rest $call S.copy_out ($call S.slice (v, need, $call carry.size ()))
        $decl c    $call carry.clear ()
        $decl w    $call carry.write (rest)
        $decl ret3 $call Co.some (body)
      }.ret3 none
  }.ret2
}.ret

// ----------------------------------------------------------- writing messages

// A message: its body written first, since the header gives its length.
$decl send $func ($decl v J.null) {
  $decl body $call S.text ()
  $decl wb   $call J.write (body, v)
  $decl head $call S.text ()
  $decl h1   $call head.write ("Content-Length: ")
  $decl h2   $call F.int (head, $call body.size ())
  $decl h3   $call head.write ("\u{d}\n\u{d}\n")
  $decl w1   $call print ($call S.raw_str ($call head.view ()))
  $decl w2   $call print ($call S.raw_str ($call body.view ()))
  $decl f    $call I.stdout.flush ()
  $decl ret  ()
}.ret

$decl envelope $func () {
  $decl o   $call J.object ()
  $decl w   $call o.put ("jsonrpc", $call J.str ("2.0"))
  $decl ret o
}.ret
$decl respond $func ($decl id J.null, $decl result J.null) {
  $decl o   $call envelope ()
  $decl w1  $call o.put ("id", id)
  $decl w2  $call o.put ("result", result)
  $decl ret $call send ($call o.build ())
}.ret
$decl respond_err $func ($decl id J.null, $decl code 0, $decl msg "") {
  $decl e   $call J.object ()
  $decl e1  $call e.put ("code", $call J.num (code))
  $decl e2  $call e.put ("message", $call J.str (msg))
  $decl o   $call envelope ()
  $decl w1  $call o.put ("id", id)
  $decl w2  $call o.put ("error", $call e.build ())
  $decl ret $call send ($call o.build ())
}.ret
$decl notify $func ($decl method "", $decl params J.null) {
  $decl o   $call envelope ()
  $decl w1  $call o.put ("method", $call J.str (method))
  $decl w2  $call o.put ("params", params)
  $decl ret $call send ($call o.build ())
}.ret

// --------------------------------------------------------------- positions

// The two hex digits at `i` of `s` as a number, or -1.
$decl hex2 $func ($decl s "", $decl i 0)
  $if ($call lt ($call len (s), $call add (i, 2))) -1 {
    $decl hi   $call J.hex_val ($call byte (s, i))
    $decl lo   $call J.hex_val ($call byte (s, $call add (i, 1)))
    $decl ret2 $if ($call Co.or ($call lt (hi, 0), $call lt (lo, 0))) -1
                   ($call add ($call mul (hi, 16), lo))
  }.ret2

// The file a `file://` URI names, with its `%XX` escapes decoded; anything else as it is.
$decl unescape_go $func ($decl s "", $decl i 0, $decl start 0, $decl b S.proto_text)
  $if ($call lt (i, $call len (s)))
      ($if ($call eq ($call byte (s, i), 37)) {
         $decl h    $call hex2 (s, $call add (i, 1))
         $decl ret2 $if ($call lt (h, 0)) ($call unescape_go (s, $call add (i, 1), start, b))
             ($do ($call b.write ($call slice (s, start, i)))
                  ($do ($call b.code (h))
                       ($call unescape_go (s, $call add (i, 3), $call add (i, 3), b))))
       }.ret2 ($call unescape_go (s, $call add (i, 1), start, b)))
      ($call b.write ($call slice (s, start, i)))
$decl uri_path $func ($decl uri "")
  $if ($call S.starts_with (uri, "file://")) {
      $decl t    $call S.text ()
      $decl w    $call unescape_go ($call slice (uri, 7, $call len (uri)), 0, 0, t)
      $decl ret2 $call S.copy_out ($call t.view ())
    }.ret2
      uri

// The byte where line `l` (from 1) starts, and where the line at `i` ends.
$decl c_nl 10
$decl line_start $func ($decl s "", $decl l 0, $decl i 0)
  $if ($call Co.or ($call lt (l, 2), $call Co.not ($call lt (i, $call len (s))))) i
      ($call line_start (s, $if ($call eq ($call byte (s, i), c_nl)) ($call sub (l, 1)) l,
                         $call add (i, 1)))
$decl line_end $func ($decl s "", $decl i 0)
  $if ($call lt (i, $call len (s)))
      ($if ($call eq ($call byte (s, i), c_nl)) i ($call line_end (s, $call add (i, 1)))) i

// A token ends at white space or punctuation.
$decl is_delim $func ($decl c 0)
  $if ($call S.is_space (c)) true
  ($if ($call eq (c, 40)) true ($if ($call eq (c, 41)) true ($if ($call eq (c, 44)) true
  ($if ($call eq (c, 123)) true ($if ($call eq (c, 125)) true ($call eq (c, 34)))))))
$decl tok_end $func ($decl s "", $decl i 0, $decl e 0)
  $if ($call lt (i, e))
      ($if ($call is_delim ($call byte (s, i))) i ($call tok_end (s, $call add (i, 1), e))) i

// The UTF-16 units the bytes `i` to `e` of `s` take: a code point beyond U+FFFF takes two,
// and a byte continuing a code point none.
$decl units_of $func ($decl b 0)
  $if ($call lt (b, 128)) 1 ($if ($call lt (b, 192)) 0 ($if ($call lt (b, 240)) 1 2))
$decl units $func ($decl s "", $decl i 0, $decl e 0, $decl acc 0)
  $if ($call lt (i, e))
      ($call units (s, $call add (i, 1), e, $call add (acc, $call units_of ($call byte (s, i)))))
      acc

$decl position $func ($decl l 0, $decl ch 0) {
  $decl o   $call J.object ()
  $decl w1  $call o.put ("line", $call J.num (l))
  $decl w2  $call o.put ("character", $call J.num (ch))
  $decl ret $call o.build ()
}.ret
$decl range $func ($decl a J.null, $decl b J.null) {
  $decl o   $call J.object ()
  $decl w1  $call o.put ("start", a)
  $decl w2  $call o.put ("end", b)
  $decl ret $call o.build ()
}.ret

// The range of the token at line `l`, byte column `c` (both from 1) of `text`; a position
// past the end of its line is that line's end, and one with no line the document's start.
$decl token_range $func ($decl text "", $decl l 0, $decl c 0)
  $if ($call lt (l, 1)) ($call range ($call position (0, 0), $call position (0, 0))) {
    $decl ls   $call line_start (text, l, 0)
    $decl le   $call line_end (text, ls)
    $decl sb0  $call Co.min ($call add (ls, $call Co.max ($call sub (c, 1), 0)), le)
    $decl te   $call tok_end (text, sb0, le)
    $decl tb   $if ($call Co.and ($call eq (te, sb0), $call lt (sb0, le)))
                   ($call Co.min ($call add (sb0, $call S.width ($call byte (text, sb0))), le)) te
    $decl ret2 $call range ($call position ($call sub (l, 1), $call units (text, ls, sb0, 0)),
                            $call position ($call sub (l, 1), $call units (text, ls, tb, 0)))
  }.ret2

// ---------------------------------------------------------------- checking

$decl diagnostic $func ($decl r J.null, $decl msg "") {
  $decl o   $call J.object ()
  $decl w1  $call o.put ("range", r)
  $decl w2  $call o.put ("severity", $call J.num (1))
  $decl w3  $call o.put ("source", $call J.str ("morphl"))
  $decl w4  $call o.put ("message", $call J.str (msg))
  $decl ret $call o.build ()
}.ret

// A diagnostic raised in another file, as `file:line:col: msg`, or `file: msg` with no line.
$decl elsewhere $func ($decl file "", $decl l 0, $decl c 0, $decl msg "") {
  $decl t   $call S.text ()
  $decl w1  $call t.write (file)
  $decl w2  $if ($call lt (0, l))
                ($do ($call t.write (":"))
                     ($do ($call F.int (t, l)) ($do ($call t.write (":")) ($call F.int (t, c))))) ()
  $decl w3  $call t.write (": ")
  $decl w4  $call t.write (msg)
  $decl ret $call S.copy_out ($call t.view ())
}.ret

// One checker diagnostic as LSP's, against the document `text` at `path`.
$decl lsp_diag $func ($decl d J.null, $decl path "", $decl text "") {
  $decl l    $call J.int_or ($call J.get (d, "line"), 0)
  $decl c    $call J.int_or ($call J.get (d, "col"), 0)
  $decl file $call J.str_or ($call J.get (d, "file"), path)
  $decl msg  $call J.str_or ($call J.get (d, "msg"), "")
  $decl ret  $if ($call eq_str (file, path))
      ($call diagnostic ($call token_range (text, l, c), msg))
      ($call diagnostic ($call token_range (text, 0, 0), $call elsewhere (file, l, c, msg)))
}.ret
$decl lsp_diags $func ($decl ds J.values.node, $decl path "", $decl text "", $decl a abuild)
  $match ds (
  $case {$prop tag "cons"}
    $do ($call a.push ($call lsp_diag (ds.head, path, text)))
        ($call lsp_diags (ds.tail, path, text, a)),
  $case ds ()
)

$decl put_at $func ($decl av $call array (0, ""), $decl i 0, $decl v "") {
  $decl c   $call at (av, i)
  $decl w   $set c v
  $decl ret ()
}.ret
$decl put_all $func ($decl av $call array (0, ""), $decl i 0, $decl xs Pa.pstrs.node) $match xs (
  $case {$prop tag "cons"}
    $do ($call put_at (av, i, xs.head)) ($call put_all (av, $call add (i, 1), xs.tail)),
  $case xs ()
)
// `/proc/self/exe --check <buffer> <path> <out> <roots…>`.
$decl check_argv $func ($decl path "") {
  $decl rs  $call Pa.pstrs.val (st.roots)
  $decl fx  $call Pa.pstrs.cons ("/proc/self/exe", $call Pa.pstrs.cons ("--check",
                $call Pa.pstrs.cons (tmp_buf, $call Pa.pstrs.cons (path,
                $call Pa.pstrs.cons (tmp_out, rs)))))
  $decl av  $call array ($call Pa.pstrs.length (fx, 0), "")
  $decl w   $call put_all (av, 0, fx)
  $decl ret av
}.ret

$decl failed_msg $func ($decl code 0) {
  $decl t   $call S.text ()
  $decl w1  $call t.write ("morphl-lsp: the checker failed (exit status ")
  $decl w2  $call F.int (t, code)
  $decl w3  $call t.write (")")
  $decl ret $call S.copy_out ($call t.view ())
}.ret

// The diagnostics of `text` as the file `path`: the checker's, or one saying it failed.
$decl check_text $func ($decl path "", $decl text "") {
  $decl u0   $call unlink (tmp_out)
  $decl wb   $call write_file (tmp_buf, text)
  $decl rc   $call run ($call check_argv (path))
  $decl code $match rc ($case {$prop tag "some"} rc.v, $case rc -1)
  $decl out  $call read_file (tmp_out)
  $decl got  $match out (
    $case {$prop tag "some"} $call J.parse (out.v),
    $case out $call J.err_at ("", 0))
  $decl a    $call J.array_of ()
  $decl w    $match got (
    $case {$prop tag "ok"} $call lsp_diags ($call J.items (got.v), path, text, a),
    $case got $call a.push ($call diagnostic ($call token_range (text, 0, 0),
        $call failed_msg (code))))
  $decl ret  $call a.build ()
}.ret

$decl publish $func ($decl uri "", $decl ds J.null) {
  $decl o   $call J.object ()
  $decl w1  $call o.put ("uri", $call J.str (uri))
  $decl w2  $call o.put ("diagnostics", ds)
  $decl ret $call notify ("textDocument/publishDiagnostics", $call o.build ())
}.ret

$decl check_doc $func ($decl uri "") {
  $decl t   $call docs.get (uri)
  $decl ret $match t (
    $case {$prop tag "some"} $call publish (uri, $call check_text ($call uri_path (uri), t.v)),
    $case t ())
}.ret

// --------------------------------------------------------------- the methods

$decl capabilities $func () {
  $decl sync $call J.object ()
  $decl s1   $call sync.put ("openClose", $call J.boolean (true))
  $decl s2   $call sync.put ("change", $call J.num (1))
  $decl sv   $call J.object ()
  $decl s3   $call sync.put ("save", $call sv.build ())
  $decl caps $call J.object ()
  $decl c1   $call caps.put ("textDocumentSync", $call sync.build ())
  $decl info $call J.object ()
  $decl i1   $call info.put ("name", $call J.str ("morphl-lsp"))
  $decl i2   $call info.put ("version", $call J.str ("0.1"))
  $decl o    $call J.object ()
  $decl o1   $call o.put ("capabilities", $call caps.build ())
  $decl o2   $call o.put ("serverInfo", $call info.build ())
  $decl ret  $call o.build ()
}.ret

// `r` against `base`, unless it is absolute.
$decl under $func ($decl base "", $decl r "") {
  $decl t   $call S.text ()
  $decl w1  $call t.write (base)
  $decl w2  $call t.write ("/")
  $decl w3  $call t.write (r)
  $decl ret $call S.copy_out ($call t.view ())
}.ret
$decl add_root $func ($decl base "", $decl r "", $decl acc Pa.pstrs.node)
  $if ($call eq_str (r, "")) acc
      ($call Pa.pstrs.cons ($if ($call S.starts_with (r, "/")) r ($call under (base, r)), acc))
// The workspace's root folder, then the roots named relative to it.
$decl rel_roots $func ($decl base "", $decl xs J.values.node, $decl acc Pa.pstrs.node) $match xs (
  $case {$prop tag "cons"}
    $call rel_roots (base, xs.tail, $call add_root (base, $call J.str_or (xs.head, ""), acc)),
  $case xs ($call Pa.pstrs.reverse (acc, Pa.pstrs.nil))
)

$decl initialize $func ($decl id J.null, $decl ps J.null) {
  $decl ru   $call J.str_or ($call J.get (ps, "rootUri"), "")
  $decl base $if ($call eq_str (ru, "")) ($call J.str_or ($call J.get (ps, "rootPath"), ""))
                 ($call uri_path (ru))
  $decl opts $call J.items ($call J.get ($call J.get (ps, "initializationOptions"), "roots"))
  $decl rs   $call rel_roots (base, opts, $call add_root ("", base, Pa.pstrs.nil))
  $decl w    $set st.roots rs
  $decl ret  $call respond (id, $call capabilities ())
}.ret

// The text a change leaves: with full synchronisation (`change: 1`) the last change is the
// whole document.
$decl last_text $func ($decl cs J.values.node, $decl t "") $match cs (
  $case {$prop tag "cons"} $call last_text (cs.tail, $call J.str_or ($call J.get (cs.head, "text"), t)),
  $case cs t
)

$decl opened $func ($decl ps J.null) {
  $decl td  $call J.get (ps, "textDocument")
  $decl uri $call J.str_or ($call J.get (td, "uri"), "")
  $decl w   $call docs.put (uri, $call J.str_or ($call J.get (td, "text"), ""))
  $decl ret $call check_doc (uri)
}.ret
$decl changed $func ($decl ps J.null) {
  $decl uri $call J.str_or ($call J.get ($call J.get (ps, "textDocument"), "uri"), "")
  $decl old $call docs.get_or (uri, "")
  $decl w   $call docs.put (uri, $call last_text ($call J.items ($call J.get (ps, "contentChanges")), old))
  $decl ret $call check_doc (uri)
}.ret
$decl saved $func ($decl ps J.null)
  $call check_doc ($call J.str_or ($call J.get ($call J.get (ps, "textDocument"), "uri"), ""))
$decl closed $func ($decl ps J.null) {
  $decl uri $call J.str_or ($call J.get ($call J.get (ps, "textDocument"), "uri"), "")
  $decl w   $call docs.remove (uri)
  $decl ret $call publish (uri, $call J.arr (J.values.nil))
}.ret

// LSP's `exit`: 0 after a `shutdown`, 1 without one.
$decl leave $func () {
  $decl u1  $call unlink (tmp_buf)
  $decl u2  $call unlink (tmp_out)
  $decl f   $call I.stdout.flush ()
  $decl ret $call c_exit ($if ($call Co.bval (st.down)) 0 1)
}.ret

$decl unknown $func ($decl m "") {
  $decl t   $call S.text ()
  $decl w1  $call t.write ("unknown method ")
  $decl w2  $call t.write (m)
  $decl ret $call S.copy_out ($call t.view ())
}.ret

$decl handle $func ($decl msg J.null) {
  $decl m   $call J.str_or ($call J.get (msg, "method"), "")
  $decl id  $call J.get (msg, "id")
  $decl ps  $call J.get (msg, "params")
  $decl req $call J.has (msg, "id")
  $decl ret $if ($call eq_str (m, "initialize")) ($call initialize (id, ps))
    ($if ($call eq_str (m, "shutdown")) ($do ($set st.down true) ($call respond (id, J.null)))
    ($if ($call eq_str (m, "exit")) ($call leave ())
    ($if ($call eq_str (m, "textDocument/didOpen")) ($call opened (ps))
    ($if ($call eq_str (m, "textDocument/didChange")) ($call changed (ps))
    ($if ($call eq_str (m, "textDocument/didSave")) ($call saved (ps))
    ($if ($call eq_str (m, "textDocument/didClose")) ($call closed (ps))
    // A request the server does not know is answered; a notification is not (JSON-RPC 2.0).
    ($if req ($call respond_err (id, -32601, $call unknown (m))) ())))))))
}.ret

$decl handle_text $func ($decl body "") {
  $decl r   $call J.parse (body)
  $decl ret $match r (
    $case {$prop tag "ok"} $call handle (r.v),
    $case r $call respond_err (J.null, -32700, "the message is not JSON"))
}.ret

// One message at a time until the input ends; a tail call, so a session is a loop (§7.7).
$decl serve $func ($decl m ($call read_message ())) $match m (
  $case {$prop tag "some"} $do ($call handle_text (m.v)) ($call serve ($call read_message ())),
  $case m ()
)

// `main` answers "", so nothing is printed after it: an answer of unit would print `0`, and
// the checker's stdout is the server's, which is the protocol's stream.
$decl main $func () $do
  ($if ($call eq_str ($call arg_at (0), "--check")) ($call check_mode ())
       ($call serve ($call read_message ())))
  ""
