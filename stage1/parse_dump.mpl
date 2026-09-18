// Parse a file with stage 1's parser and print the same S-expression dump
// stage 0's parser prints, so the two can be diffed:
//
//   morphlc --run stage1/parse_dump.mpl examples/spec12.mpl  > a
//   morphlc examples/spec12.mpl                              > b
//   diff a b
//
// Two independent implementations of §2 agreeing on real input is a much
// stronger check than either one's unit tests.

$decl Pa $import "parser"
$decl P  $import "prelude"

$decl not P.not

$decl argv $call args ()

$decl path $if ($call lt (0, $call alen (argv)))
    ($call at (argv, 0))
    ($do ($call print ("usage: morphlc --run stage1/parse_dump.mpl <file.mpl>\n"))
         ($call panic ("no input file")))

$decl src $func ($decl p "")
  { $decl c $try ($call read_file (p)) none
    $decl out c.v }.out

$decl text $call src (path)

$decl parsed $call Pa.parse (text)

$decl show_errs $func ($decl xs Pa.diags.node, $decl p "") $match xs (
  $case {$prop tag "cons"}
    $do ($call print ($call concat (p, $call concat (":", $call concat ($call int_to_str (xs.head.line),
         $call concat (":", $call concat ($call int_to_str (xs.head.col),
         $call concat (": error: ", $call concat (xs.head.msg, "\n")))))))))
        ($call show_errs (xs.tail, p)),
  $case xs ()
)

$decl printed $if ($call Pa.diags.is_nil (parsed.errs))
    ($call print ($call Pa.dump_file (parsed.exprs, "")))
    ($do ($call show_errs (parsed.errs, path))
         ($call panic ("parse failed")))
