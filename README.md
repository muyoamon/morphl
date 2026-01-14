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
### TODO
- compiler backend
- add compiler settings
- add c ffi support
- add static storage
- add multithread support (maybe)

## Building

Build and run using source program:

```
cmake -S . -B build && cmake --build build
./build/src/morphlc examples/program.src
```
