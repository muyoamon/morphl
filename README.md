# morphl

## Overview

**morphl** is a statically-typed programming language with a dynamic parser. It features a Pratt-style grammar system that can be loaded from text files, enabling flexible syntax extension without requiring recompilation of the compiler.

### Key Features

- **Dynamic Grammar System**: Grammar rules defined in text files, parsed at compile time
- **Static Type Inference**: Full type checking with no implicit coercion
- **Functional & Imperative**: Support for both paradigms
- **Structural Typing**: Records with width subtyping support
- **Traits System**: Interface-like behavior with implementations
- **First-class Functions**: Functions are values that can be passed around
- **Mutable & Immutable References**: Explicit storage modifiers

### Project Status

Currently implementing core language features. The lexer, parser, AST, and type inference system are in development.

### Documentation
- [Language Semantics](docs/semantics/storage.md)
- [Typing System](docs/typing/typing.md)
- [Specification](SPEC.md)
- [VM Bytecode Format](docs/backend/vm_bytecode.md)
### TODO
- compiler backend
- add compiler settings
- add c ffi support
- add static storage
- add multithread support (maybe)


### Backend selection

By default `morphlc` uses the VM backend, emits binary bytecode to `out.mbc`, and immediately runs it. Use `-c` to compile without execution. You can select the C backend to emit `out.c`, or override either default path with `-o <filename>`. VM bytecode uses a magic header, string table, metadata section, and opcodes documented in `docs/backend/vm_bytecode.md`. Runtime Morphl operator symbols are preserved verbatim through string table entries used by the `OPERATOR` opcode, while compile-time operators are resolved during compilation.

```
./build/src/morphlc examples/minimal.mpl
./build/src/morphlc -c examples/minimal.mpl
./build/src/morphlc -o build/custom.mbc examples/minimal.mpl
./build/src/morphlc --backend c -o build/custom.c examples/minimal.mpl
```

## Building

Build and run using a source program:

```
cmake -S . -B build && cmake --build build
./build/src/morphlc examples/minimal.mpl
```

Compile without execution:

```
./build/src/morphlc -c examples/minimal.mpl
./build/src/morphlc --backend c examples/minimal.mpl
```
