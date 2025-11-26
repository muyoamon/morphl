# morphl
programming language



### TODO
- refactor code (important)
- fix macro system
- add compiler settings
- add c ffi support
- add static storage
- add multithread support (maybe)

## Dynamic tokenizer

The lexer loads token rules from a text file. Each non-empty line describes a
token as `<NAME> <literal>`, for example:

```
LBRACE {
RBRACE }
ARROW "->"
PLUS +
```

Quoted literals support the escapes `\n`, `\t`, `\\`, and `\"`. After loading
the syntax file, the compiler tokenizes a source file that you provide on the
command line:

```
cmake -S . -B build && cmake --build build
./build/src/morphlc examples/syntax.txt examples/program.src
```

Identifiers and numbers are recognized automatically, and an EOF token is
appended to every token stream.
