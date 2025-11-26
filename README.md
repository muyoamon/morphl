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
parser consumes a Pratt-style grammar loaded from a text file. Grammar files
declare blocks with `rule <name>:` followed by one or more pattern/template
pairs and terminated by `end`.

Patterns may contain literals, token kinds (e.g. `%IDENT`), and expression
placeholders of the form `$expr[n]` where *n* is the minimum binding power for
that operand. Associativity is encoded solely by the binding power choices on
each side of an operator.

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
