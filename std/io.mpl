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
$decl lines_go $func ($decl s "", $decl i 0, $decl start 0, $decl acc strs.node)
  $if ($call lt (i, $call len (s)))
      ($if ($call eq ($call byte (s, i), c_nl))
           ($call lines_go (s, $call add (i, 1), $call add (i, 1),
                $call strs.cons ($call slice (s, start, i), acc)))
           ($call lines_go (s, $call add (i, 1), start, acc)))
      ($call strs.reverse ($if ($call lt (start, i))
           ($call strs.cons ($call slice (s, start, i), acc)) acc, strs.nil))
$decl lines $func ($decl s "") $call lines_go (s, 0, 0, strs.nil)

// §8's `concat` copies both operands, so joining n pieces by appending is O(n²). This
// joins adjacent pairs until one is left: log₂ n passes, each copying the text once.
$fwd join_pass
$decl join_pair $func ($decl x "", $decl rest strs.node, $decl acc strs.node) $match rest (
  $case {$prop tag "cons"}
    $call join_pass ($call strs.val (rest.tail),
        $call strs.cons ($call concat (x, rest.head), acc)),
  $case rest ($call strs.reverse ($call strs.cons (x, acc), strs.nil))
)
$decl join_pass $func ($decl xs strs.node, $decl acc strs.node) $match xs (
  $case {$prop tag "cons"} $call join_pair (xs.head, $call strs.val (xs.tail), acc),
  $case xs ($call strs.reverse (acc, strs.nil))
)
$fwd join_all
$decl join_more $func ($decl xs strs.node, $decl rest strs.node) $match rest (
  $case {$prop tag "cons"} $call join_all ($call join_pass (xs, strs.nil)),
  $case rest ""
)
$decl join_all $func ($decl xs strs.node) $match xs (
  $case {$prop tag "cons"}
    $if ($call strs.is_nil ($call strs.val (xs.tail))) xs.head
        ($call join_more (xs, $call strs.val (xs.tail))),
  $case xs ""
)

// Each line followed by a newline, joined.
$decl unlines $func ($decl xs strs.node)
  $call join_all ($call strs.map (xs, $func ($decl s "") $call concat (s, "\n")))

$decl read_lines  $func ($decl path "") $call C.map_opt ($call read_file (path), lines)
$decl write_lines $func ($decl path "", $decl xs strs.node)
  $call write_file (path, $call unlines (xs))

// §8's `args ()` — the program's arguments, without its name — as a list.
$decl arg_list $func () $call strs.from_array ($call args ())
