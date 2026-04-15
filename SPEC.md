# morphl Language Specification

> **Status**: Draft — design is active and evolving. Sections marked ⚠️ are unsettled.

---

## 1. Design Philosophy

morphl is a statically typed, structurally typed language designed around the following core principles:

**Verbatim execution** — program flow maps directly to written code. There are no implicit allocations, implicit copies, implicit conversions, or hidden control flow. Every runtime action corresponds to something the programmer explicitly wrote.

**Everything is a declaration** — all named entities are introduced via `$decl`. There is no syntactic distinction between variables, structs, functions, or modules. Type is implied structurally through the shape of declarations.

**No namespace pollution** — all language keywords are prefixed with `$`, reserving the unprefixed namespace entirely for user-defined identifiers.

**Explicit storage** — mutability, indirection, and ownership are expressed through storage expressions, not through separate annotation syntax.

---

## 2. Keyword Namespace

Every language keyword is prefixed with `$`. This ensures language constructs never conflict with user-defined field names.

Reserved keywords include: `$decl`, `$prop`, `$mut`, `$const`, `$ref`, `$new`, `$func`, `$ret`, `$call`, `$impl`, `$traits`, `$import`, `$extern`, `$set`, `$null`, `$this`, `$parent`, `$file`, `$global`, `$exit`, `$if`, `$while`, `$break`, `$continue`, `$and`, `$or`, `$not`.

---

## 3. Core Construct: `$decl`

### 3.1 Declaration as Shape Definition

`$decl` is the single construct for introducing a named entity into a scope. It does not perform allocation or execution — it defines the **shape** of the enclosing block by binding a name to a storage expression.

```
$decl <name> <storage-expr>;
```

`$decl` contributes three things to the enclosing block:

- The **name** of the field
- The **type**, inferred from the storage expression
- The **byte offset** in the block's layout, determined by declaration order with natural alignment

### 3.2 Block as Value

A block delimited by `{}` is both a struct and a code block — they are the same construct. Statements inside a block are initialization logic. The block's **type** is the structural shape of its surviving `$decl` expressions.

```
$decl x {
    $decl a 10;
    a = a + 1;
};
// type of x: { a: i32 }
// a = 11 at capture time
```

`$decl` **suspends** the expression — the block executes once at declaration site and captures its final state. Referencing `x` later does not re-execute the block.

### 3.3 Re-execution via `$new`

`$new` re-executes a block's initialization logic to produce a fresh, independent instance:

```
$decl p $new x;    // fresh instance, a = 11, independent of x
$decl q $new x;    // another fresh instance, independent of p
```

Mutating `p.a` does not affect `q.a`.

### 3.4 Default Mutability

A bare expression used as a storage expression is sugar for `$const`:

```
$decl foo 10;         // sugar for: $decl foo $const 10
```

---

## 4. Storage Expressions

Storage expressions determine the runtime behavior of a declaration. `$decl` only binds a name — all storage semantics come from the expression.

### 4.1 `$const` — Immutable Storage

```
$decl foo $const 10;
```

Allocates immutable storage initialized to the given value. The value cannot be overwritten after initialization.

### 4.2 `$mut` — Mutable Storage

```
$decl foo $mut 10;
```

Allocates mutable storage. The value can be overwritten via assignment.

### 4.3 `$ref` — Reference (Relative Offset)

```
$decl r $ref x;
```

`$ref` is not a pointer — it is a **relative offset** to an existing storage location. It has fixed size regardless of the referent's type, which enables recursive type definitions.

`$ref` is transparent in expressions — using `r` in an expression reads/writes through to `x`'s storage. The `$ref` keyword is only needed when explicitly bridging to the reference itself.

**As a local alias**: compile-time only, no runtime storage allocated.

**As a struct field**: runtime storage (a signed integer relative offset).

```
$decl x $mut 5;
$decl r $ref x;

r + 1;      // transparent — reads x, computes 6
r = 10;     // transparent — writes 10 to x's storage
```

**Lifetime rule**: a `$ref` must not outlive its target. A `$ref` field stored in a struct may only safely reference data in the same frame or a longer-lived (parent) frame. The compiler does not enforce this in v1.0 — it is a programmer responsibility. Storing a `$ref` to a local that is subsequently popped results in undefined behavior.

### 4.4 Mutability Subtyping

Mutable storage satisfies immutable expectations, but not vice versa:

```
{ x: $mut i32 } <: { x: $const i32 }   // safe — mutable can be read as immutable
{ x: $const i32 } </: { x: $mut i32 }  // unsafe — cannot write to immutable
```

**`$mut`/`$const` on `$ref` fields**: the qualifier on a `$ref` describes access through the reference, not the storage of the reference slot itself:

```
$decl x $mut 5;
$decl r $const $ref x;   // read-only access through r, even though x is $mut
$decl w $mut   $ref x;   // read-write access (valid because x is $mut)
```

`$mut $ref x` is only valid when x is itself `$mut`. `$const $ref x` is always valid regardless of x's own mutability.

### 4.5 `$extern` — Native Symbol Binding

`$extern` is a storage specifier that binds a name to a native C symbol resolved at load time. Its type is inferred from the wrapped expression, exactly as with other storage specifiers:

```
$decl <name> $extern <expr>;
```

The symbol name used for resolution is the `$decl` name itself.

**Native function binding** — the most common form:

```
$decl println   $extern $func ($decl s "") 0;   // (string) → i64
$decl print_int $extern $func ($decl n 0) 0;    // (i64)    → i64
```

The `$func` expression is used only for its type; its body is not emitted. The VM stores a function table index in the declared slot; at call time the dispatcher invokes the native C function pointer instead of interpreting bytecode.

**Native constant binding** (v2 — via `dlsym`):

```
$decl ERRNO $extern i64;
```

The value is loaded from the native symbol at program load time.

**Resolution order** at program load:

1. Built-in static registry — populated by `morphl_stdlib_register()`, called automatically before any user code runs.
2. dlopen fallback — if the symbol is not in the static registry, the runtime looks for a shared library with the same base name as the importing `.mpl` file (`.so` on Linux, `.dylib` on macOS). If found, it calls `morphl_module_register` from that library to register additional symbols.
3. If the symbol remains unresolved after both steps, loading fails with an error.

**Writing a native module** (user-extensible FFI):

```c
// my_module.c  →  compile to  my_module.so
#include "runtime/runtime.h"

static int64_t my_add(uint8_t* stack, size_t frame_base, size_t param_size) {
    int64_t a, b;
    memcpy(&b, stack + frame_base - 8,  8);
    memcpy(&a, stack + frame_base - 16, 8);
    return a + b;
}

void morphl_module_register(MorphlRegisterFn reg) {
    reg("my_add", my_add);
}
```

Place `my_module.so` next to `my_module.mpl`. The runtime locates it automatically when that `.mpl` file is imported.

**Native function signature:**

```c
typedef int64_t (*MorphlNativeFn)(uint8_t* stack, size_t frame_base, size_t param_size);
```

Arguments sit below `frame_base` in declaration order, 8 bytes each. The last argument is at `stack[frame_base - 8]`. The return value should be returned as `int64_t`.

### 4.6 Storage Expression Summary

| Expression | Meaning | Writable |
|---|---|---|
| `$const expr` | immutable storage | no |
| `$mut expr` | mutable storage | yes |
| `$ref name` | alias to existing storage | depends on referent |
| `$new block` | fresh instance via re-execution | depends on fields |
| `$import "file"` | reference to external file scope | no |
| `$extern expr` | native C symbol binding | no |
| bare `expr` | sugar for `$const expr` | no |

---

## 5. Structural Type System

### 5.1 Types Are Implied by Declaration Shape

There are no explicit type annotations for structs. A type is the set of field names and their storage kinds as declared:

```
$decl point {
    $decl x $mut 0;
    $decl y $mut 0;
};
// type: { x: $mut i32, y: $mut i32 }
```

### 5.2 Structural Subtyping

Two types are compatible if one's fields are a prefix match of the other's at identical byte offsets. A type `A` is a structural subtype of `B` if every field in `B` exists in `A` at the same offset with a compatible type.

```
type Animal { age: i32, weight: f64 }
type Dog    { age: i32, weight: f64, name: $ref u8 }

Dog <: Animal   // prefix matches, offsets identical
```

### 5.3 Struct Layout

Fields are laid out in **declaration order with natural alignment**. Padding is inserted to align each field to its own size. This guarantees stable, predictable offsets across all implementations — the foundation of structural subtyping across module boundaries.

```
$decl Foo {
    $decl a i32;    // offset 0  (4 bytes)
                    // offset 4  (4 bytes padding)
    $decl b f64;    // offset 8  (8 bytes)
    $decl c i32;    // offset 16 (4 bytes)
                    // offset 20 (4 bytes padding)
};
// total: 24 bytes
```

Fields are **never reordered** by the compiler. Reordering would break the prefix-match subtyping guarantee.

### 5.4 Recursive Types via `$ref`

Direct recursive fields are impossible because the type has no finite size:

```
$decl Node { $decl value i32; $decl next Node; };  // error — infinite size
```

`$ref` breaks the cycle by storing a fixed-size relative offset regardless of the referent's size:

```
$decl Node {
    $decl value i32;
    $decl next $ref Node;   // fixed size: sizeof(relative_offset)
};
```

### 5.5 `$null`

`$null` is defined as `$decl $null $ref $null` — a reference that refers to itself, forming an unresolvable indirection chain. It is not a value per se but a sentinel indicating "this reference points to nothing." Dereferencing `$null` is an error.

**Concrete representation**: `$null` is stored as the relative offset `INT32_MIN` (0x80000000). The `RNULL` opcode pushes this value. `DEREF` traps at runtime if it encounters `INT32_MIN`. `JNULL` branches when the top of stack equals `INT32_MIN`.

---

## 6. Functions

### 6.1 `$func` Declaration

Functions are first-class values declared with `$func`. The argument list is a **pseudo-scope** pasted before the function body in the scope chain:

```
$decl f $func ($decl x i32) {
    $decl y x + 1;
};
// type: (i32) => { y: i32 }
```

### 6.2 Argument Pseudo-Scope

Arguments live in a scope outside the function body. They are readable inside the body via scope resolution but are **not captured** into the body's structural type. Arguments are caller-owned and cleaned up by the caller (cdecl convention).

### 6.3 Return Semantics

**Implicit return** — if no `$ret` is used, the entire function body is the return value. Its type is the structural shape of the body's captured declarations:

```
$decl make_point $func ($decl x i32, $decl y i32) {
    $decl px x;
    $decl py y;
};
// type: (i32, i32) => { px: i32, py: i32 }
```

**Explicit return** — `$ret expr` returns a specific value and exits the function early:

```
$decl f $func ($decl x i32) {
    $ret x + 1;
};
// type: (i32) => i32
```

`$ret` is scoped to the nearest enclosing `$func`. It does not propagate through nested blocks.

**Mixed paths** — if some code paths use `$ret` and others rely on implicit return, the types must unify. A compile error is emitted if they do not.

### 6.4 Encapsulation via `$ret`

`$ret` is the sole encapsulation mechanism. Without it, all declarations in the body are exposed in the return type. With it, only the explicitly returned value is exposed:

```
$decl f $func ($decl x i32) {
    $decl result x + 1;
    $decl tmp 999;       // implementation detail
    $ret { result };     // only result is exposed
};
// type: (i32) => { result: i32 }
```

### 6.5 `$exit` — Explicit Process Exit

`$exit` terminates the process immediately with a given integer exit code:

```
$exit 0;      // exit with code 0 (success)
$exit 1;      // exit with code 1
$exit code;   // exit with value of 'code' (must be i32)
```

Rules:
- The argument must be of type `i32`. Any other type is a compile error.
- `$exit` can appear anywhere in top-level code or inside a function.
- There is no `$exit` with zero arguments — use `$exit 0` for explicit success exit.

### 6.6 `main` — Program Entry Point

If a top-level declaration named `main` is present and has the signature `() => i32`, the VM backend automatically calls it after all top-level statements have executed, and uses its return value as the process exit code.

```
$decl main $func () {
    // program logic
    $ret 0;   // exit code
};
```

Constraints enforced at compile time:
- `main` **must** have return type `i32`. Any other return type is a compile error.
- `main` takes no explicit arguments (the hidden `$parent` argument is always present).
- If no `main` is declared, top-level code runs and exits with code 0 on `HALT`.

Interaction with `$exit`:
- `$exit` within `main` exits immediately with the given code, bypassing the return value.
- `$exit` at top-level (outside `main`) exits before `main` is called.
- Simple scripts with neither `main` nor `$exit` run to completion and exit 0.

### 6.7 Function Type Signature

```
(<arg-types>) => <return-type>
```

Functions are contravariant in argument types and covariant in return type for subtyping purposes.

### 6.6 Calling Convention

The caller pre-allocates the return slot before the call. The body writes directly into the return slot (sret convention for struct returns). On `$ret` or end of body, the pseudo-scope is discarded — the return value is already in place with no copy needed.

Stack layout at call time:

```
| caller frame               |
| return slot                |  ← pre-allocated by caller
|----------------------------|
| pseudo-scope (args)        |  ← pushed at call, popped after
| function body              |  ← writes to return slot directly
```

### 6.7 Function Table

All functions are entries in a global function table. A function value at runtime is a `u32` index into this table. This makes function pointers relocatable and safe — no absolute addresses, no forgeable indices.

```
FuncTable[n] = { bytecode_offset, arity, frame_size }
```

---

## 7. Control Flow

### 7.1 `$if` — Conditional Expression

```
$if <cond> <then> [<else>]
```

Evaluates `<cond>` (must be of type `bool` or `i32`). If truthy (non-zero), executes `<then>`; otherwise executes `<else>` if present. The else branch is optional.

```
$if $lt x 10 {
    $set x $add x 1;
};

$if $eq x 0 {
    $ret 1;
} {
    $ret x;
};
```

- Condition must be `bool` (result of a comparison) or `i32` (truthy if non-zero).
- The two forms accept any expression as branches — including blocks `{}` or bare values.
- Both branches should produce compatible types when the `$if` result is used as a value.

### 7.2 `$while` — Loop

```
$while <cond> <body>
```

Repeatedly evaluates `<cond>`. If truthy, executes `<body>` and re-evaluates; if falsy, exits the loop.

```
$decl i $mut 0;
$while $lt i 10 {
    $set i $add i 1;
};
```

- Condition is re-evaluated before every iteration.
- `<body>` is a block expression `{}` (or any single expression).
- Variables declared inside the body are re-initialized on each iteration; they are not accessible after the loop exits.

**Known limitation**: `$break`/`$continue` nested inside a sub-block within the body (with its own scope allocation) bypass the sub-block's `LEAVE` instruction. Avoid nesting `$break`/`$continue` inside inner `{}` blocks within a while body until scope unwinding is implemented.

### 7.3 `$break` and `$continue` — Loop Control

`$break` exits the nearest enclosing `$while` immediately.

`$continue` skips the remainder of the current iteration and re-evaluates the loop condition.

```
$decl i $mut 0;
$while 1 {
    $set i $add i 1;
    $if $eq i 5 { $break; };
};
// i == 5 here

$decl sum $mut 0;
$decl j $mut 0;
$while $lt j 10 {
    $set j $add j 1;
    $if $eq $mod j 2 1 { $continue; };   // skip odd j
    $set sum $add sum j;
};
```

Both `$break` and `$continue` take no arguments. Using either outside a `$while` body is a compile error.

### 7.4 Logical Operators

```
$and <lhs> <rhs>   — logical AND (short-circuit)
$or  <lhs> <rhs>   — logical OR  (short-circuit)
$not <expr>        — logical NOT
```

Operands may be `bool` (result of a comparison) or `i32` (truthy if non-zero). The result is always `bool` (0 or 1 as i32).

**Short-circuit evaluation**: `$and` does not evaluate `<rhs>` if `<lhs>` is false; `$or` does not evaluate `<rhs>` if `<lhs>` is true.

```
$decl a 1;
$decl b 0;

$and a b;          // 0 — both are evaluated
$or  a b;          // 1 — rhs not evaluated (a is truthy)
$not a;            // 0
$not 0;            // 1

$if $and $gt x 0 $lt x 100 {
    // x is in (0, 100)
};
```

---

## 8. Scope Contexts

Every scope maintains a set of reserved context references. These are `$ref`-based — relative offsets following the same semantics as user-defined references.

| Reference | Meaning |
|---|---|
| `$this` | the current block instance |
| `$parent` | the enclosing block instance |
| `$file` | the current file's scope |
| `$global` | the root/global scope |
| `$global.$parent` | `$null` — root has no parent |

`$this` refers to the immediate scope, not any outer scope. Inside a function body, `$this` is the function's own block, not the enclosing module.

```
$decl mod {
    $decl x 0;
    $decl f $func () {
        $this;      // f's own body — { }
        $parent;    // mod's instance
        $parent.x;  // mod's x field
    };
};
```

The scope chain is a `$ref`-linked structure terminating at `$global.$parent = $null`. Traversal is uniform — the same machinery as user-defined `$ref` chains.

---

## 9. Properties

### 9.1 `$prop` Declaration

Properties are declared with `$prop` and accessed with the `$` prefix:

```
$decl mod {
    $decl x 0;
    $prop PI 3.14;
};

mod.x;      // field access
mod.$PI;    // property access
```

Properties are extra context attached to a block. They are constant once declared — they cannot be reassigned.

### 9.2 Properties Are Not Structurally Fixed

Properties do not have fixed byte offsets and do not participate in structural subtyping. Two blocks with different field declaration order but identical `$decl` fields and identical properties have the same type:

```
$decl mod1 { $decl x 0; $prop PI 3.14; };
$decl mod2 { $prop PI 3.14; $decl x 0; };
// both have type: { x: i32 }($PI: f64)
```

### 9.3 Full Type Signature

A type's full signature has two components:

```
{ <structural fields> }($<property name>: <type>, ...)
```

Structural subtyping only considers the structural component. A function requiring `{ x: i32 }` accepts both `mod1` and `mod2` — it ignores properties. A function requiring `{ x: i32 }($PI: f64)` requires the property to be present.

### 9.4 Properties as Methods

Properties can hold function values, making them constant method-like members:

```
$decl mod {
    $decl x $mut 0;
    $prop describe $func () {
        $ret $parent.x;
    };
};
```

---

## 10. Traits

### 10.1 Trait Declaration

A trait defines a set of properties that can be implemented by any type. Traits may only contain properties — no structural fields:

```
$decl TraitA $traits {
    $prop propA 30;
    $prop methodB $func () 0;
};
```

### 10.2 Trait Implementation via `$impl`

`$impl` derives a new type from an existing type by injecting trait properties. The original type is never modified:

```
$decl typeD {
    $decl x 0;
    $decl y 0;
};

$decl typeE $impl TraitA typeD {
    $prop propA 99;
    $prop methodB $func () { $ret $parent.x; };
};
```

If the implementation block is omitted, the trait's default property values are used. Partial overrides are allowed — unspecified properties use the trait's defaults.

`typeE` is a structural subtype of `typeD`:

```
typeE <: typeD   // structural fields are identical
typeD </: typeE  // typeD lacks TraitA's properties
```

### 10.3 Trait-Typed Variables

A variable can be declared with a trait type. It can hold any value that implements that trait:

```
$decl traitVar TraitA;
$set traitVar typeE;    // valid — typeE implements TraitA
$set traitVar typeD;    // error — typeD does not implement TraitA
```

### 10.4 Trait Variable Representation

A trait-typed variable is a fat block with two `$ref` fields:

```
traitVar ~= {
    $impl: $ref <property table>     // points to trait property implementations
    $data: $ref <concrete instance>  // points to actual data
}
```

This is a regular block using existing `$ref` machinery — no special VM support needed. The property table is a singleton block produced once per `$impl`.

Calling a trait method:

```
$call traitVar.$methodB ();
// 1. load traitVar.$impl
// 2. load $impl.$methodB  (function table index)
// 3. set $parent = traitVar.$data
// 4. CALLF
```

---

## 11. Modules and Imports

### 11.1 Files as Blocks

A file is a block. Its type is the structural shape of its top-level `$decl` expressions. `$file` is the reserved reference to the current file's scope.

### 11.2 `$import`

`$import` is a storage expression that loads an external file's scope:

```
$decl module $import "some_module";
module.some_var;
```

Inline import without binding:

```
($import "some_module").some_var;
```

The imported module's type is structurally inferred from its file scope. No separate interface file or explicit export list is required — all top-level declarations are visible.

### 11.3 Standard Library

The built-in IO stdlib is in `stdlib/io.mpl`. Import it to access basic IO functions:

```
$decl io $import "stdlib/io.mpl";
$call $member io println ("hello, world");
$call $member io print_int (42);
```

Available symbols:

| Name | Signature | Description |
|---|---|---|
| `print` | `(string) → i64` | write string to stdout |
| `println` | `(string) → i64` | write string + newline to stdout |
| `print_int` | `(i64) → i64` | write integer to stdout |
| `eprint` | `(string) → i64` | write string to stderr |
| `eprintln` | `(string) → i64` | write string + newline to stderr |

All IO functions return `0` on success.

### 11.4 Native Modules

Any `.mpl` file can have a companion native library (`.so` / `.dylib`) with the same base name. Symbols declared with `$extern` in the `.mpl` file are resolved from that library at load time via `morphl_module_register`. See §4.5 for the full resolution protocol and the native function signature.

---

## 12. Grammar System

morphl has two parsing modes that can coexist in the same program: the **builtin parser** and the **grammar-driven parser**. Both produce the same AST; they differ in how the programmer writes source code.

### 12.1 Builtin Parser

The builtin parser is always available. It requires no configuration and no grammar file. All language constructs are written using `$`-prefixed operator keywords in prefix notation:

```
$op arg1 arg2 ...
```

**Argument boundaries** are determined by the operator's registered maximum arity (`max_args`). Once the argument count reaches `max_args`, the parser stops consuming tokens for that operator and returns. This is how nested operators are unambiguous:

```
$while $lt i 5 { ... }
// $lt has max_args=2: consumes 'i' and '5', then stops
// $while gets $lt(i,5) as cond and { ... } as body
```

**Token rules for the builtin parser:**
- `$`-prefixed identifiers are operator heads — their arguments are the next `max_args` expressions
- `{ stmt; ... }` is a **block** expression (AST_BLOCK) — statements separated by `;`
- `( expr, ... )` is a **group** expression (AST_GROUP) — comma-separated
- Bare identifiers and literals are leaf expressions
- The following symbols terminate an argument list: `)`, `}`, `]`, `;`, `,`

### 12.2 Custom Grammar Files

The builtin prefix-notation syntax is the canonical representation, but morphl allows blocks to switch to an infix/natural-language syntax via a **grammar file**. A grammar file defines how surface syntax maps to the same builtin AST operators.

Grammar files are plain text with `.g` or `.txt` extension. They define named **rules** as Pratt-style productions:

```
rule <rule_name>:
    <pattern> => <template>
    <pattern> => <template>
    ...
end
```

Multiple rules may appear in one file. The **first rule** is the start rule for that grammar. An alternate production is written as another line under the same rule.

Rule ordering is semantically significant. Earlier productions always take precedence over later ones when both could match.

**Complete example:**

```
rule program:
    $($stmnt s)*  => $$spread s
end

rule stmnt:
    $expr exp ";"  => exp
end

rule expr:
    %NUMBER              => number
    %IDENT               => ident
    "return" $expr val   => $ret val
    "while" $expr cond $expr body => $while cond body
    "if" $expr cond $expr thn "else" $expr el => $if cond thn el
    "if" $expr cond $expr thn                 => $if cond thn
    "{" $($stmnt s)* "}" => $block $$spread s
    "(" $expr inner ")"  => inner
    $expr[20] func "(" $expr params ")" => $call func params
    $expr[1]  lhs "+" $expr[2]  rhs => $add lhs rhs | $fadd lhs rhs
    $expr[1]  lhs "-" $expr[2]  rhs => $sub lhs rhs | $fsub lhs rhs
    $expr[10] lhs "*" $expr[11] rhs => $mul lhs rhs | $fmul lhs rhs
    $expr[10] lhs "/" $expr[11] rhs => $div lhs rhs | $fdiv lhs rhs
    $expr     id  ":=" $expr exp    => $decl id exp
    $expr     lhs "="  $expr rhs    => $set  lhs rhs
end
```

### 12.3 Pattern Atoms

Each production pattern is a sequence of **atoms**:

| Atom syntax | Meaning |
|---|---|
| `"literal"` | Match the exact token lexeme (keyword, punctuation, operator symbol) |
| `%IDENT` | Match any identifier token |
| `%NUMBER` | Match any integer literal token |
| `%FLOAT` | Match any float literal token |
| `%STRING` | Match any string literal token |
| `$rule_name` | Recursively match `rule_name` with binding power 0 |
| `$rule_name[n]` | Recursively match `rule_name` requiring binding power ≥ n |
| `$( atoms )* ` | Match zero or more repetitions of the sub-pattern |
| `$( atoms )+` | Match one or more repetitions |
| `capture_name` | A bare word (not quoted, no `$`/`%`) acts as a **capture label** — names the preceding atom's result for use in the template |

Capture labels bind to the immediately preceding atom. If placed before the first atom, they bind forward.

### 12.4 Operator Precedence via Binding Power

Binding power (`[n]`) controls precedence and associativity in a Pratt-style fashion. Higher numbers bind tighter.

```
$expr[1]  lhs "+" $expr[2]  rhs   // left-associative:  lhs bp≥1, rhs bp≥2
$expr[10] lhs "*" $expr[11] rhs   // left-associative:  higher precedence than +
$expr[15] lhs "^" $expr[15] rhs   // right-associative: lhs and rhs same bp
```

- **Left-associative**: rhs binding power = lhs binding power + 1
- **Right-associative**: rhs binding power = lhs binding power (same value)
- **Higher number = tighter binding**: `*` at `[10]` binds tighter than `+` at `[1]`

A production whose first atom is a `$rule_name` (or labeled rule reference) is treated as an **infix/postfix production**. The Pratt loop offers it only when the current left-hand expression has sufficient binding power.

### 12.5 Template Directives

Templates describe how matched captures become AST nodes. A template is a space-separated sequence of tokens after `=>`:

```
<pattern> => $op capture1 capture2 ...
```

The first token names the AST operator; subsequent tokens are children. In addition to capture names, special directives are available:

| Directive | Meaning |
|---|---|
| `$$spread name` | Flatten all children of the captured node as individual children (useful for repetition results) |
| `$$maybe name` | Include the captured node only if it was matched (for optional sub-patterns) |
| `$$op name` | Use the captured identifier's lexeme as the operator name (dynamic dispatch to builtin) |
| `capture_name` | Insert the captured node as a child of the result |

[!NOTE]
`$$op` with an unrecognized builtin name is a compile-time error, reported during the codegen pass with a reference to grammar rule that produced it.

**Overload alternatives** — a template can offer multiple candidates separated by `|`. The type checker selects the matching variant:

```
$expr[1] lhs "+" $expr[2] rhs => $add lhs rhs | $fadd lhs rhs
```

This produces an `AST_OVERLOAD` node; the type inference pass resolves it to `$add` (integers) or `$fadd` (floats) based on the operand types.

**Using `$$spread` with repetition:**

```
rule program:
    $($stmnt s)*  => $$spread s   // spread all matched stmnts into a flat block
end
```

`$($stmnt s)*` matches zero or more `stmnt` productions, collecting them all into capture `s`. `$$spread s` then flattens them as siblings in the resulting AST node.

### 12.6 The `$syntax` Directive

`$syntax` activates a custom grammar for the current scope:

```
$syntax "path/to/grammar.g";
```

Rules:
- The argument is a **string literal** containing the path to a grammar file.
- Paths are resolved **relative to the source file's directory**.
- `$syntax` is a preprocessor directive — it is consumed during parsing and **does not appear in the AST**.
- Grammar activation applies to **all statements following `$syntax`** in the same block.
- On **block exit**, the grammar reverts to the parent block's grammar (LIFO stack).

**Scope example:**

```
// file: main.mpl
$syntax "mygrammar.g";    // active from here to end of file (or enclosing block)

x := 10;                  // parsed with mygrammar.g
y := x + 5;               // parsed with mygrammar.g

{                         // inner block inherits mygrammar.g
    z := y * 2;           // also mygrammar.g
};                        // grammar reverts to mygrammar.g on block exit (same here)
```

**Mixing builtin and custom grammar:**

When a custom grammar is active, the following builtin directives remain unconditionally available regardless of the grammar:

- `$syntax` — to switch grammars in a nested block
- `$import` — to import another file
- `$decl`, `$prop`, `$func`, `$traits`, `$impl` — structural declarations

All other constructs are parsed through the custom grammar's productions.

**Nesting grammars** — different blocks in the same file may use different grammars:

```
$syntax "grammar_a.g";
a_style_code;

{
    $syntax "grammar_b.g";   // grammar_b active for this block only
    b_style_code;
}                            // reverts to grammar_a

more_a_style_code;
```

### 12.7 Relationship Between the Two Parsers

The grammar-driven parser and the builtin parser produce **identical AST representations**. A program written entirely in builtin syntax:

```
$decl result $add $mul a b c;
```

is semantically equivalent to a grammar rule that maps `a * b + c` to `$add ($mul a b) c`. The grammar is purely a surface transformation — there are no runtime semantics attached to grammar rules.

---

## 13. VM Opcode Set

The VM uses **typed opcodes** — the operand type and size are encoded in the opcode itself, not in the values. Values on the stack are raw bits with no runtime type tags.

### 13.1 Load / Store

```
ILOAD  <offset>    — load i32 from frame offset
FLOAD  <offset>    — load f64 from frame offset
RLOAD  <offset>    — load relative offset ($ref) from frame offset
ISTORE <offset>    — store i32 to frame offset
FSTORE <offset>    — store f64 to frame offset
RSTORE <offset>    — store relative offset to frame offset
```

### 13.2 Constants

```
ICONST <imm>       — push i32 literal
FCONST <imm>       — push f64 literal
RNULL              — push $null reference
```

### 13.3 Arithmetic

```
IADD  ISUB  IMUL  IDIV  IMOD   — i32 arithmetic
FADD  FSUB  FMUL  FDIV         — f64 arithmetic
```

### 13.4 Comparison

```
IEQ  INEQ  ILT  IGT  ILTE  IGTE   — i32 comparisons, push bool
FEQ  FNEQ  FLT  FGT  FLTE  FGTE   — f64 comparisons, push bool
REQ  RNEQ                          — reference equality
```

### 13.5 Type Conversion

```
I2F    — convert i32 → f64
F2I    — convert f64 → i32 (truncate)
```

### 13.6 Scope / Block

```
ENTER  <size>      — push new scope region of <size> bytes
LEAVE  <size>      — pop scope region
```

### 13.7 Function Call

```
RESERVE <size>     — pre-allocate return slot in caller frame
CALL    <index>    — direct call by function table index
CALLF   <offset>   — indirect call: load function index from frame offset, then dispatch
RET                — pop pseudo-scope, return to caller
```

Each function table entry carries a `flags` field. When `flags & NATIVE` is set, `entry_point` is an index into the program's native function pointer array rather than a bytecode offset. The dispatcher invokes the C function pointer directly; `RET` is not executed — the native function returns via the normal C call stack and its `int64_t` return value is written to `stack[frame_base - 8]`.

### 13.8 Reference / Indirection

```
ADDREF  <offset>   — compute relative offset to a frame location
DEREF              — resolve a relative offset to its target location
PLOAD   <offset>   — load field from $parent via its $ref
PSTORE  <offset>   — store field to $parent via its $ref
```

### 13.9 Block Instantiation

```
NEW <offset> <size>   — re-execute block at <offset>, write result into <size> bytes
```

`NEW` is the only opcode that re-executes logic. It corresponds directly to `$new` in source.

### 13.10 Control Flow

```
JMP   <label>      — unconditional jump
JIF   <label>      — jump if top of stack is truthy
JNULL <label>      — jump if top of stack is $null reference
```

### 13.11 Process Control

```
EXIT               — pop i64 from stack; exit the process with that value as exit code
```

`EXIT` is emitted by `$exit expr` and by the `main` auto-call convention. It unconditionally terminates the VM and propagates the exit code to the host OS.

### 13.12 Design Notes

- No GC opcodes — memory is stack-managed and explicit
- No type tag opcodes — types are encoded in instructions, not values
- No dynamic dispatch opcodes — structural subtyping resolves to field offsets at compile time
- No implicit copy opcodes — copies are explicit load/store pairs
- Function pointers are `u32` indices into the global function table

---

## 14. Type System Summary

| Layer | Mechanism | Participates in subtyping |
|---|---|---|
| Structural fields | `$decl`, fixed byte offsets | yes — prefix match |
| Properties | `$prop`, no fixed offset | no |
| Traits | `$traits` + `$impl` | via property table |
| Mutability | `$mut` / `$const` in field type | yes — `$mut <: $const` |
| References | `$ref`, relative offset | yes — same as referent type |

---

## 15. Grammar Reference (Informal)

```
program     ::= decl*
decl        ::= '$decl' name storage-expr ';'
             |  '$prop' name expr ';'
storage-expr::= '$mut' expr
             |  '$const' expr
             |  '$ref' name
             |  '$new' expr
             |  '$import' string
             |  '$func' '(' params ')' block
             |  '$traits' block
             |  '$impl' name name block?
             |  expr
block       ::= '{' stmt* '}'
stmt        ::= decl
             |  expr ';'
             |  '$ret' expr? ';'
             |  '$exit' expr ';'
             |  '$set' name expr ';'
             |  '$call' expr expr ';'
             |  '$if' expr expr expr? ';'
             |  '$while' expr block ';'
             |  '$break' ';'
             |  '$continue' ';'
params      ::= (decl (',' decl)*)?
expr        ::= name
             |  literal
             |  expr '.' name
             |  expr '$' name
             |  '(' expr ')'
             |  expr op expr
             |  '$if' expr expr expr?
             |  '$while' expr block
             |  '$and' expr expr
             |  '$or'  expr expr
             |  '$not' expr
             |  '$this' | '$parent' | '$file' | '$global' | '$null'
             |  '(' '$import' string ')'
```

---

## 16. Resolved Design Decisions

The following questions were previously open; they are now settled.

**Implicit `$parent` in method calls** — when emitting `$call obj.method args`, the caller pushes `$parent = &obj` as a hidden argument before the normal arguments, matching the existing calling convention (caller-owned, cleaned up after CALL). The VM emitter is responsible for inserting this push. This is consistent with the existing `$parent` slot at `frame[0]` inside every function body.

**`$null` representation** — `RNULL` pushes `INT32_MIN` (0x80000000) as the null sentinel. `DEREF` traps at runtime if it encounters this value. `JNULL` branches when the top of stack equals `INT32_MIN`. The self-referential definition `$decl $null $ref $null` in §5.5 maps to this concrete value.

**Cross-frame `$ref` lifetime** — a `$ref` must not outlive its target. A `$ref` field stored in a struct may only safely reference data in the same frame or a longer-lived (parent) frame. This rule is not enforced by the compiler in v1.0; it is a programmer responsibility documented here. Violating it (e.g. storing a `$ref` to a local that is then popped) results in undefined behavior.

**`$mut` / `$const` on `$ref` fields** — the mutability qualifier on a `$ref` describes access through the reference, not storage of the reference itself:
- `$const $ref x` — read-only access through the ref, regardless of x's own mutability.
- `$mut $ref x` — read-write access through the ref, but only valid if x is itself `$mut`.
The ref's own storage (the signed relative-offset integer) is always fixed-size and always writable as a slot (it is the access semantics that are controlled, not the ref slot).

**Property table dispatch for `$parent`** — when a trait method is called through a fat trait variable (`traitVar.$impl.$methodB`), the calling sequence is: (1) load `traitVar.$impl` to get the property table ref, (2) load the method's function-table index from the property table, (3) load `traitVar.$data` and push it as `$parent`, (4) CALLF. The `$parent` slot at the callee's `frame[0]` then points to the concrete data instance, not the fat variable itself.
