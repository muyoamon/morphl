# MorphL Language Specification

## Overview

**MorphL** is a statically-typed programming language with a dynamic parser and static tokenizer. It features a Pratt-style grammar system that can be loaded from text files, enabling flexible syntax extension without requiring recompilation of the compiler.

### Key Features

- **Dynamic Grammar System**: Grammar rules defined in text files, parsed at compile time
- **Static Type Inference**: Full type checking with no implicit coercion
- **Functional & Imperative**: Support for both paradigms
- **Structural Typing**: Records with width subtyping support
- **Traits System**: Interface-like behavior with implementations
- **First-class Functions**: Functions are values that can be passed around
- **Mutable & Immutable References**: Explicit storage modifiers

---

## Core Language Constructs

### Literals

```
42              // integer
3.14            // float
"text"          // string
```

### Basic Declarations

#### Immutable Binding
```
$decl name value
```

#### Mutable Reference
```
$decl x $mut 0      // x is a mutable reference to 0
```

#### Const Reference
```
$decl x $const 0    // x is a const reference to 0
```

#### Inline (Alias)
```
$decl x $inline 0   // x aliases 0
```

### Functions

#### Function Definition
```
$decl f1 $func ($decl x 0, $decl y 0) $add x y
```

A function is defined with:
- Parameters: declared as `$decl` bindings
- Body: a single expression (which can be a block)
- Return value: the value of the body expression

#### Function Calls
```
$call name $group arg1 arg2 ...
```

All function calls are expressed via `$call`; surface syntax is lowered to this form.

#### Default Arguments

Missing call arguments take parameter defaults if the parameter has a default value. This enables subtyping-by-shorter argument list.

```
$decl add $func ($decl x 0, $decl y 0) $add x y
$call add 5             // equivalent to $call add $group 5 0
```

### Conditionals

```
$if condition then-else group
```

The condition must evaluate to a boolean. Both branches are expressions and return a value.

```
$decl abs $func ($decl n 0) {
    $if $gte n 0
        $ret n,
        $ret $neg n
}
```

### Blocks & Groups

#### Block (Structural Record)
```
$block stmnt1 stmnt2 ...
```

Blocks are structures that act as scopes. They can contain declarations and statements.

```
$decl x {
    $decl a 1
    $decl b "foo"
    $set a $add a 1
}
```

Blocks have a type signature based on their members:
- Only `$decl` members are part of the type (properties are excluded)
- Field order matters for record equality

#### Group (Ordered Tuple)
```
$group expr1 expr2 ...
```

Groups are ordered tuples used for collecting multiple expressions.

### Assignments

```
$set target value
```

Updates the value at a mutable reference.

### Return Statement

```
$ret value
```

Early return from a function. Returns the value immediately, bypassing remaining statements.

---

## Built-in Operators

### Arithmetic

- `$add` - Addition
- `$sub` - Subtraction
- `$mul` - Multiplication
- `$div` - Division

### Float Arithmetic

- `$fadd` - Float addition
- `$fsub` - Float subtraction
- `$fmul` - Float multiplication
- `$fdiv` - Float division

### Bitwise Operations

- `$band` - Bitwise AND
- `$bor` - Bitwise OR
- `$bnot` - Bitwise NOT
- `$lshift` - Left shift
- `$rshift` - Right shift

### Logical Operations

- `$and` - Logical AND
- `$or` - Logical OR
- `$not` - Logical NOT

### Comparison

- `$eq` - Equality
- `$neq` - Not equal
- `$gt` - Greater than
- `$lt` - Less than
- `$gte` - Greater than or equal
- `$lte` - Less than or equal

### Special Operators

- `$member obj field` - Access object member
- `$this` - Current scope reference
- `$neg expr` - Negation

---

## Type System

### Type Inference

MorphL uses automatic type inference from literal values:

```
$decl x 10              // x : int
$decl y 3.14            // y : float
$decl s "hi"            // s : string
```

### Subtyping Rules

1. **Empty group** is a subtype of any type
2. **Individual expression** is a subtype of a group if types match the first element
3. **Block subtyping**: A block type is a subtype of another if it's an extension (same fields in same order, plus additional fields)

#### Type Extension
```
$decl x {
    $decl a 10
}                       // x: {a: int}

$decl y $extend x {
    $decl b 20
}                       // y: {a: int, b: int}

$decl v1 $mut x
$set v1 y               // Works (subtyping)
$member v1 a            // Works
$member v1 b            // Error - v1 has type x, no member b
```

### No Implicit Coercion

All built-in operators have no implicit coercion. Type mismatches are compile-time errors. User-defined operations may implement coercion if desired.

---

## Advanced Features

### Forward Declarations

Enable recursion and mutual recursion:

```
$decl fact $forward $func ($decl n 0) 0
$decl fact $func ($decl n 0) {
    $if $eq n 0
        $ret 1,
        $ret $mul n ($call fact $sub n 1)
}
```

#### Rules
- `$forward` marks an unresolved function stub
- Stub must specify parameters (names, order, defaults) and return type placeholder
- Later `$decl` with same name must provide the body; parameters must match exactly
- Exactly one `$forward` per name per scope
- Body must appear in the same scope
- Calls allowed after stub; type comes from stub

#### Mutual Recursion
```
$decl even $forward $func ($decl n 0) 0
$decl odd $forward $func ($decl n 0) 0

$decl even $func ($decl n 0) {
    $if $eq n 0
        $ret 1,
        $ret $call odd $sub n 1
}

$decl odd $func ($decl n 0) {
    $if $eq n 0
        $ret 0,
        $ret $call even $sub n 1
}
```

### Properties & Traits

#### Properties

Properties are preprocessing members that don't appear in type signatures:

```
$decl x {
    $decl a 10
    $prop b 100
}                       // x: {a: int}  (no b in type)
```

Access via `$member`:
```
$member x a             // 10
$member x $b            // 100 (property requires $ prefix)
```

#### Traits

Define shared behavior (similar to interfaces/protocols):

```
$decl loggable $traits {
    $prop log $func ($this) $void
}

$decl x {
    $decl a 0
}

$impl loggable x, {
    $prop log $func ($this) {...}
}

$call $member x $log ()   // Call the trait method
```

Traits can be applied to any type, including primitives:

```
$decl y 10
$impl loggable y, {
    $prop log $func ($this) {...}
}
```

### Module System

#### Import
```
$decl mod1 $import "module1"
```

Imports are essentially block bindings containing the module's file-level scope.

#### Namespacing
- `$this` - Current scope
- `$file` - File-level scope
- `$global` - Global scope

```
$decl x {
    $decl a 0
    $member $this a     // Equivalent to x.a
}
```

### Meta Operations

#### Convert Identifier to String
```
$idtstr %identifier%
```

#### Convert String to Identifier
```
$strtid "literal"
```

---

## Grammar System

### Overview

The parser uses a Pratt-style grammar loaded from text files. Grammar rules declare patterns and templates to build the AST.

### Rule Declaration

```
rule expr:
    %NUMBER => $intlit
    %IDENT => $ident
    $expr lhs "+" $expr[1] rhs => $add lhs rhs
end
```

### Pattern Components

- **Literals**: `"+"`, `"-"`, etc.
- **Token kinds**: `%IDENT`, `%NUMBER`, etc.
- **Rule placeholders**: `$name[n]` where n is binding power (defaults to 0)

### Binding Power & Associativity

Binding power controls precedence and associativity:

```
rule expr:
    $expr lhs "+" $expr[1] rhs => $add lhs rhs     // left-associative
    $expr[10] lhs "*" $expr[11] rhs => $mul lhs rhs // tighter than +
end
```

### Overload Resolution

Multiple alternatives separated by `|` create an overload set:

```
rule expr:
    $expr lhs "+" $expr[1] rhs => $add lhs rhs | $fadd lhs rhs
end
```

The type checker resolves which candidate to use based on operand types.

### Pattern Modifiers

- **Inline grouping**: `$( pattern )` - group a subpattern
- **One or more**: `+` - match one or more repetitions
- **Zero or more**: `*` - match zero or more repetitions
- **Optional**: `?` - match zero or one
- **Delimiter**: `$$delim` - marks delimiter for greedy operations
- **Spread**: `$$spread` - flatten group to individual atoms
- **Maybe**: `$$maybe` - allow optional atom

#### Example: Comma-separated Expressions
```
rule expr:
    $expr first $("," $expr)+ rest => $group first $$spread rest
end
```

---

## Design Invariants

These invariants are locked for implementation:

1. All built-in operators have arity ≤ 2
2. Calls are expressed via `$call`; surface syntax lowers to `$call`
3. No implicit coercion for built-ins; mismatched types are errors
4. Missing call arguments take parameter defaults
5. Default values are parameter initializers in `$func` declarations
6. Blocks are structural records; groups are ordered tuples
7. Field order matters for record equality
8. Subtyping: shorter arglists accepted if missing args have defaults
9. Records may have width subtyping (more fields viewed as fewer)
10. Recursion via `$mut` placeholder or `$forward` declarations

---

## Compiler Usage

```bash
cmake -S . -B build && cmake --build build
./build/src/morphlc <grammar-file> <source-file>
```

Example:
```bash
./build/src/morphlc examples/grammar.txt examples/program.src
```

---

## File Structure

- **Lexer** (`src/lexer/`) - Static tokenization
- **Parser** (`src/parser/`) - Dynamic Pratt-style parsing
- **AST** (`src/ast/`) - Abstract syntax tree representation
- **Typing** (`src/typing/`) - Type inference and checking
- **Utilities** (`src/util/`) - Error handling, file I/O, helpers

---

## Future Enhancements

- Refactor core code
- Fix macro system
- Compiler settings support
- C FFI (Foreign Function Interface)
- Static storage support
- Multithreading support (maybe)
