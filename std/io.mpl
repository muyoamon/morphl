// std/io: the platform group (§8) in the shapes a program wants — lines, whole files,
// the argument list — over `print`, `eprint`, `read_file`, `write_file` and `args`.
// A failure that is expected is a value (§4.15): reading answers an option, writing
// `unit` or `err`.

$decl C $import "std/core"
$decl L $import "std/list"

$decl strs $specialize L.list ""

$decl print_line  $func ($decl s "") $do ($call print (s)) ($call print ("\n"))
$decl eprint_line $func ($decl s "") $do ($call eprint (s)) ($call eprint ("\n"))

// A whole file, or `none` when it cannot be read or is not UTF-8 (§3.1); and a whole file
// written, truncating, answering `unit` or `err`.
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

// §8's `concat` copies both operands, so joining n pieces by appending is O(n²). This
// joins adjacent pairs until one is left: log₂ n passes, each copying the text once.
$fwd join_pass
$decl join_pair $func ($decl x "", $decl rest strs.node, $decl acc strs.node) $match rest (
  $case {$prop tag "cons"}
    $call join_pass ($call cl.val (rest.tail), $call cl.cons ($call concat (x, rest.head), acc)),
  $case rest ($call cl.reverse ($call cl.cons (x, acc), strs.nil))
)
$decl join_pass $func ($decl xs strs.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} $call join_pair (xs.head, $call cl.val (xs.tail), acc),
  $case xs ($call cl.reverse (acc, strs.nil))
)
$fwd join_all
$decl join_more $func ($decl xs strs.node, $decl rest strs.node) $match rest (
  $case {$prop tag "cons"} $call join_all ($call join_pass (xs, strs.nil)),
  $case rest ""
)
$decl join_all $func ($decl xs strs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call cl.is_nil ($call cl.val (xs.tail))) xs.head
        ($call join_more (xs, $call cl.val (xs.tail))),
  $case xs ""
)

// Each line followed by a newline, in reverse, in front of `acc`.
$decl ended $func ($decl xs strs.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"}
    $call ended ($call cl.val (xs.tail), $call cl.cons ($call concat (xs.head, "\n"), acc)),
  $case xs acc
)

// Each line followed by a newline, joined.
$decl unlines $func ($decl xs ($call strs.empty ()))
  $call join_all ($call cl.reverse ($call ended (xs.cells, strs.nil), strs.nil))

$decl read_lines  $func ($decl path "") $call C.map_opt ($call read_file (path), lines)
$decl write_lines $func ($decl path "", $decl xs ($call strs.empty ()))
  $call write_file (path, $call unlines (xs))

// §8's `args ()` — the program's arguments, without its name — as a list.
$decl arg_list $func () $call strs.from_array ($call args ())
