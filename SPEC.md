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

Reserved keywords include: `$decl`, `$prop`, `$mut`, `$const`, `$ref`, `$new`, `$func`, `$ret`, `$call`, `$impl`, `$traits`, `$import`, `$set`, `$null`, `$this`, `$parent`, `$file`, `$global`, `$exit`.

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

### 4.4 Mutability Subtyping

Mutable storage satisfies immutable expectations, but not vice versa:

```
{ x: $mut i32 } <: { x: $const i32 }   // safe — mutable can be read as immutable
{ x: $const i32 } </: { x: $mut i32 }  // unsafe — cannot write to immutable
```

### 4.5 Storage Expression Summary

| Expression | Meaning | Writable |
|---|---|---|
| `$const expr` | immutable storage | no |
| `$mut expr` | mutable storage | yes |
| `$ref name` | alias to existing storage | depends on referent |
| `$new block` | fresh instance via re-execution | depends on fields |
| `$import "file"` | reference to external file scope | no |
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

## 7. Scope Contexts

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

## 8. Properties

### 8.1 `$prop` Declaration

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

### 8.2 Properties Are Not Structurally Fixed

Properties do not have fixed byte offsets and do not participate in structural subtyping. Two blocks with different field declaration order but identical `$decl` fields and identical properties have the same type:

```
$decl mod1 { $decl x 0; $prop PI 3.14; };
$decl mod2 { $prop PI 3.14; $decl x 0; };
// both have type: { x: i32 }($PI: f64)
```

### 8.3 Full Type Signature

A type's full signature has two components:

```
{ <structural fields> }($<property name>: <type>, ...)
```

Structural subtyping only considers the structural component. A function requiring `{ x: i32 }` accepts both `mod1` and `mod2` — it ignores properties. A function requiring `{ x: i32 }($PI: f64)` requires the property to be present.

### 8.4 Properties as Methods

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

## 9. Traits

### 9.1 Trait Declaration

A trait defines a set of properties that can be implemented by any type. Traits may only contain properties — no structural fields:

```
$decl TraitA $traits {
    $prop propA 30;
    $prop methodB $func () 0;
};
```

### 9.2 Trait Implementation via `$impl`

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

### 9.3 Trait-Typed Variables

A variable can be declared with a trait type. It can hold any value that implements that trait:

```
$decl traitVar TraitA;
$set traitVar typeE;    // valid — typeE implements TraitA
$set traitVar typeD;    // error — typeD does not implement TraitA
```

### 9.4 Trait Variable Representation

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

## 10. Modules and Imports

### 10.1 Files as Blocks

A file is a block. Its type is the structural shape of its top-level `$decl` expressions. `$file` is the reserved reference to the current file's scope.

### 10.2 `$import`

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

---

## 11. VM Opcode Set

The VM uses **typed opcodes** — the operand type and size are encoded in the opcode itself, not in the values. Values on the stack are raw bits with no runtime type tags.

### 11.1 Load / Store

```
ILOAD  <offset>    — load i32 from frame offset
FLOAD  <offset>    — load f64 from frame offset
RLOAD  <offset>    — load relative offset ($ref) from frame offset
ISTORE <offset>    — store i32 to frame offset
FSTORE <offset>    — store f64 to frame offset
RSTORE <offset>    — store relative offset to frame offset
```

### 11.2 Constants

```
ICONST <imm>       — push i32 literal
FCONST <imm>       — push f64 literal
RNULL              — push $null reference
```

### 11.3 Arithmetic

```
IADD  ISUB  IMUL  IDIV  IMOD   — i32 arithmetic
FADD  FSUB  FMUL  FDIV         — f64 arithmetic
```

### 11.4 Comparison

```
IEQ  INEQ  ILT  IGT  ILTE  IGTE   — i32 comparisons, push bool
FEQ  FNEQ  FLT  FGT  FLTE  FGTE   — f64 comparisons, push bool
REQ  RNEQ                          — reference equality
```

### 11.5 Type Conversion

```
I2F    — convert i32 → f64
F2I    — convert f64 → i32 (truncate)
```

### 11.6 Scope / Block

```
ENTER  <size>      — push new scope region of <size> bytes
LEAVE  <size>      — pop scope region
```

### 11.7 Function Call

```
RESERVE <size>     — pre-allocate return slot in caller frame
CALL    <index>    — direct call by function table index
CALLF   <offset>   — indirect call: load function index from frame offset, then dispatch
RET                — pop pseudo-scope, return to caller
```

### 11.8 Reference / Indirection

```
ADDREF  <offset>   — compute relative offset to a frame location
DEREF              — resolve a relative offset to its target location
PLOAD   <offset>   — load field from $parent via its $ref
PSTORE  <offset>   — store field to $parent via its $ref
```

### 11.9 Block Instantiation

```
NEW <offset> <size>   — re-execute block at <offset>, write result into <size> bytes
```

`NEW` is the only opcode that re-executes logic. It corresponds directly to `$new` in source.

### 11.10 Control Flow

```
JMP   <label>      — unconditional jump
JIF   <label>      — jump if top of stack is truthy
JNULL <label>      — jump if top of stack is $null reference
```

### 11.11 Process Control

```
EXIT               — pop i64 from stack; exit the process with that value as exit code
```

`EXIT` is emitted by `$exit expr` and by the `main` auto-call convention. It unconditionally terminates the VM and propagates the exit code to the host OS.

### 11.12 Design Notes

- No GC opcodes — memory is stack-managed and explicit
- No type tag opcodes — types are encoded in instructions, not values
- No dynamic dispatch opcodes — structural subtyping resolves to field offsets at compile time
- No implicit copy opcodes — copies are explicit load/store pairs
- Function pointers are `u32` indices into the global function table

---

## 12. Type System Summary

| Layer | Mechanism | Participates in subtyping |
|---|---|---|
| Structural fields | `$decl`, fixed byte offsets | yes — prefix match |
| Properties | `$prop`, no fixed offset | no |
| Traits | `$traits` + `$impl` | via property table |
| Mutability | `$mut` / `$const` in field type | yes — `$mut <: $const` |
| References | `$ref`, relative offset | yes — same as referent type |

---

## 13. Grammar Reference (Informal)

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
params      ::= (decl (',' decl)*)?
expr        ::= name
             |  literal
             |  expr '.' name
             |  expr '$' name
             |  '(' expr ')'
             |  expr op expr
             |  '$this' | '$parent' | '$file' | '$global' | '$null'
             |  '(' '$import' string ')'
```

---

## 14. Open Design Questions

⚠️ **Implicit `$parent` in method calls** — the mechanism by which `$parent` is wired as calling context when invoking block-declared functions is not yet fully specified.

⚠️ **`$null` representation** — the concrete sentinel value for `$null` in relative offset storage is not yet determined.

⚠️ **Cross-frame `$ref` lifetime** — rules governing whether a `$ref` may point into a parent frame, and what happens when the parent frame is popped, are not yet settled.

⚠️ **Property table dispatch for `$parent`** — how `$parent` resolves correctly when a trait method is called through a fat trait variable is not yet fully specified.

⚠️ **`$mut` / `$const` on `$ref` fields** — the interaction between reference mutability and referent mutability needs precise definition.
