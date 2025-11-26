# morphl
programming language



### TODO
- refactor code (important)
- fix macro system
- add compiler settings
- add c ffi support
- add static storage
- add multithread support (maybe)

## Dynamic parser and static tokenizer

The lexer now uses static rules (identifiers, numbers, punctuation) while the
parser consumes a grammar loaded from a text file. Grammar files support
`:=` (define) and `+=` (append) operators, rule references with `$name`, and
token-kind matches with `%KIND`.

Example grammar excerpt:

```
rule expr:
    %NUMBER => $number
    %IDENT => $ident
    "(" $expr[0] ")" => $group
    "-" $expr[30] rhs => $neg rhs
    $expr[0] lhs "+" $expr[1] rhs => $add lhs rhs
    $expr[0] lhs "-" $expr[1] rhs => $sub lhs rhs
    $expr[10] lhs "*" $expr[11] rhs => $mul lhs rhs
    $expr[10] lhs "/" $expr[11] rhs => $div lhs rhs
end
```

Build and run using a grammar file and source program:

```
cmake -S . -B build && cmake --build build
./build/src/morphlc examples/grammar.txt examples/program.src
```
