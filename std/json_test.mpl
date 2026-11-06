// std/json's tests, as inline checks run by `std/test`: `mplc std/json_test.mpl -L . -o …`
// from the repository root. A failure is reported on stderr and aborts; `main` answers how
// many passed, which `zig build test-std` compares.

$decl C $import "std/core"
$decl J $import "std/json"
$decl S $import "std/str"
$decl T $import "std/test"

// The text `s` reads back as, or the failure as `err <msg> at <pos>`.
$decl again $func ($decl s "") {
  $decl r   $call J.parse (s)
  $decl ret $match r (
    $case {$prop tag "ok"}  $call J.text (r.v),
    $case {$prop tag "err"} $call concat ("err ", $call concat (r.msg,
                              $call concat (" at ", $call int_to_str (r.pos)))))
}.ret
$decl same $func ($decl s "", $decl want "") $call eq_str ($call again (s), want)

// The value `s` holds, or `null` when it does not parse.
$decl val $func ($decl s "") {
  $decl r   $call J.parse (s)
  $decl ret $match r ($case {$prop tag "ok"} r.v, $case r J.null)
}.ret

$decl doc $call val ($call concat ("{\"id\": 7, \"method\": \"init\", \"ok\": true,\n",
                                    "  \"params\": {\"xs\": [10, -2, 3.5], \"name\": null}}"))

$decl main $func () {
  $decl r   $call T.results ()
  $decl c1  $call T.expect (r, "scalars", $call C.and ($call same ("true", "true"),
                $call C.and ($call same ("false", "false"), $call same (" null ", "null"))))
  $decl c2  $call T.expect (r, "numbers keep their text",
                $call same ("[0, -1, 12.25, 1e9, -0.5E-3]", "[0,-1,12.25,1e9,-0.5E-3]"))
  $decl c3  $call T.expect (r, "escapes read",
                $call same ("\"a\\\"b\\\\c\\/d\\n\\t\\r\\b\\f\"", "\"a\\\"b\\\\c/d\\n\\t\\r\\u0008\\u000c\""))
  $decl c4  $call T.expect (r, "\\u escapes and surrogate pairs",
                $call same ("\"\\u00e9\\u4e2d\\ud83d\\ude00\"", "\"é中😀\""))
  $decl c5  $call T.expect (r, "whitespace between tokens",
                $call same (" { \"a\" :\n[ 1 ,2 ] , \"b\"\t: { } } ", "{\"a\":[1,2],\"b\":{}}"))
  $decl c6  $call T.expect (r, "members in order, a key twice kept twice",
                $call same ("{\"z\":1,\"a\":2,\"z\":3}", "{\"z\":1,\"a\":2,\"z\":3}"))
  $decl c7  $call T.expect (r, "get and the accessors",
                $call C.and ($call eq ($call J.int_or ($call J.get (doc, "id"), -1), 7),
                $call C.and ($call eq_str ($call J.str_or ($call J.get (doc, "method"), ""), "init"),
                             $call J.bool_or ($call J.get (doc, "ok"), false))))
  $decl ps  $call J.get (doc, "params")
  $decl xs  $call J.get (ps, "xs")
  $decl c8  $call T.expect (r, "at, and a number that is not an integer",
                $call C.and ($call eq ($call J.int_or ($call J.at (xs, 1), 0), -2),
                             $call eq ($call J.int_or ($call J.at (xs, 2), 0), 0)))
  $decl c9  $call T.expect (r, "what is not there is null",
                $call C.and ($call J.is_null ($call J.get (doc, "nope")),
                $call C.and ($call J.is_null ($call J.at ($call J.get (ps, "xs"), 3)),
                $call C.and ($call J.is_null ($call J.get ($call J.get (doc, "id"), "x")),
                             $call J.is_null ($call J.at (doc, 0))))))
  $decl c10 $call T.expect (r, "has tells a null member from no member",
                $call C.and ($call J.has (ps, "name"), $call C.not ($call J.has (ps, "nope"))))
  $decl c11 $call T.expect (r, "a value of the wrong kind reads as the default",
                $call C.and ($call eq_str ($call J.str_or ($call J.get (doc, "id"), "d"), "d"),
                             $call eq ($call J.int_or ($call J.get (doc, "method"), 9), 9)))
  $decl c12 $call T.expect (r, "kind and length",
                $call C.and ($call eq_str ($call J.kind (ps), "obj"),
                $call C.and ($call eq ($call J.length (ps), 2),
                $call C.and ($call eq ($call J.length ($call J.get (ps, "xs")), 3),
                             $call eq ($call J.length ($call J.get (doc, "id")), 0)))))
  $decl o   $call J.object ()
  $decl o1  $call o.put ("jsonrpc", $call J.str ("2.0"))
  $decl o2  $call o.put ("id", $call J.num (-12))
  $decl a   $call J.array_of ()
  $decl a1  $call a.push ($call J.boolean (true))
  $decl a2  $call a.push (J.null)
  $decl a3  $call a.push ($call J.str ("q\"\u{1}\n"))
  $decl o3  $call o.put ("result", $call a.build ())
  $decl c13 $call T.expect (r, "built and written",
                $call eq_str ($call J.text ($call o.build ()),
                    "{\"jsonrpc\":\"2.0\",\"id\":-12,\"result\":[true,null,\"q\\\"\\u0001\\n\"]}"))
  $decl c14 $call T.expect (r, "unfinished input",
                $call C.and ($call same ("[1,", "err unexpected end of input at 3"),
                $call C.and ($call same ("\"abc", "err unterminated string at 4"),
                $call C.and ($call same ("", "err unexpected end of input at 0"),
                             $call same ("{\"a\":1", "err expected ',' or '}' at 6")))))
  $decl c15 $call T.expect (r, "malformed input",
                $call C.and ($call same ("[1 2]", "err expected ',' or ']' at 3"),
                $call C.and ($call same ("{\"a\" 1}", "err expected ':' at 5"),
                $call C.and ($call same ("{1:2}", "err expected a string at 1"),
                $call C.and ($call same ("tru", "err unexpected character at 0"),
                             $call same ("[nul]", "err unexpected character at 1"))))))
  $decl c16 $call T.expect (r, "numbers outside the grammar",
                $call C.and ($call same ("01", "err unexpected text after the value at 1"),
                $call C.and ($call same ("-", "err expected a digit at 1"),
                $call C.and ($call same ("1.", "err expected a digit after '.' at 2"),
                $call C.and ($call same ("1e+", "err expected a digit in the exponent at 3"),
                             $call same ("+1", "err unexpected character at 0"))))))
  $decl c17 $call T.expect (r, "strings outside the grammar",
                $call C.and ($call same ("\"\\x\"", "err invalid escape in string at 1"),
                $call C.and ($call same ("\"\\ud800\"", "err invalid escape in string at 1"),
                $call C.and ($call same ("\"\\u12\"", "err invalid escape in string at 1"),
                             $call same ("\"a\nb\"", "err control character in string at 2")))))
  // Every loop is a tail call, so neither of these grows the stack: a block around the
  // recursive call made the first one crash.
  $decl long $call S.repeat ("ab\\n", 500000)
  $decl c18 $call T.expect (r, "a long string and a long array",
                $call C.and ($call eq ($call len ($call J.str_or ($call val ($call concat ("\"",
                                 $call concat (long, "\""))), "")), 1500000),
                             $call eq ($call J.length ($call val ($call concat ("[",
                                 $call concat ($call S.repeat ("0,", 300000), "0]")))), 300001)))
  $decl ret $call T.finish (r)
}.ret
