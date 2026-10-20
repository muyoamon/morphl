// std/io: the platform group (§8) in the shapes a program wants — lines, whole files,
// the argument list — over `print`, `eprint`, `read_file`, `write_file` and `args`.
// A failure that is expected is a value (§4.15): reading answers an option, writing
// `unit` or `err`.

$decl C $import "std/core"
$decl L $import "std/list"
$decl S $import "std/str"

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

// Each line followed by a newline, joined pairwise by `std/str` (D6).
$decl unlines $func ($decl xs ($call strs.empty ()))
  $if ($call xs.is_empty ()) "" ($call concat ($call S.join (xs, "\n"), "\n"))

$decl read_lines  $func ($decl path "") $call C.map_opt ($call read_file (path), lines)
$decl write_lines $func ($decl path "", $decl xs ($call strs.empty ()))
  $call write_file (path, $call unlines (xs))

// §8's `args ()` — the program's arguments, without its name — as a list.
$decl arg_list $func () $call strs.from_array ($call args ())
