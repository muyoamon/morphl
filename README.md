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
start := $function
function := %IDENT "(" $params ")" "->" $expr ";"
params := %IDENT $params_tail
params +=
params_tail := "," %IDENT $params_tail
params_tail +=
expr := $term $expr_tail
expr_tail := "+" $term $expr_tail
expr_tail +=
term := $factor $term_tail
term_tail := "*" $factor $term_tail
term_tail +=
factor := "(" $expr ")"
factor += %IDENT
factor += %NUMBER
```

Build and run using a grammar file and source program:

```
cmake -S . -B build && cmake --build build
./build/src/morphlc examples/grammar.txt examples/program.src
```
