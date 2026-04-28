# morphl Language Specification

> **Status**: Draft — design is active and evolving. Sections marked ⚠️ are unsettled.

---

## 1. Design Philosophy

morphl is a statically typed, structurally typed language designed around the following core principles:

**Verbatim execution** — program flow maps directly to written code. There are no implicit allocations, implicit copies, implicit conversions, or hidden control flow. Every runtime action corresponds to something the programmer explicitly wrote.

**Everything is an expression** - morphl has no statements. Every construct produces a value. Control flow, declarations, blocks, and functions calls are expressions terminated by `$$delim` or `;`. The distinction between statement and expression does not exist.

**Everything is a declaration** — all named entities are introduced via `$decl`. There is no syntactic distinction between variables, structs, functions, or modules. Type is implied structurally through the shape of declarations.

**No namespace pollution** — all language keywords are prefixed with `$`, reserving the unprefixed namespace entirely for user-defined identifiers.

**Explicit storage** — mutability, indirection, and ownership are expressed through storage expressions, not through separate annotation syntax.

---

## 2. Keyword Namespace

Every language keyword is prefixed with `$`. This ensures language constructs never conflict with user-defined field names.

### 2.1 Single-`$` Keywords 
Reserved keywords include: `$decl`, `$prop`, `$mut`, `$const`, `$ref`, `$new`, `$func`, `$ret`, `$call`, `$impl`, `$traits`, `$import`, `$extern`, `$set`, `$null`, `$this`, `$parent`, `$file`, `$global`, `$exit`, `$defer`, `$if`, `$while`, `$break`, `$continue`, `$and`, `$or`, `$not`, `$union`, `$array`, `$never`, `$as`, `$overload`.

### 2.2 Double-`$$` Directives
`$$`-prefixed name are compiler directives - They are as-early-as-possible resolutions. The compiler substitute them at compile time whenever it can determine the value statically. If it cannot, resolution defers to runtime

Reserved directives: `$$syntax`, `$$spread`, `$$maybe`, `$$op`, `$$type`, `$$size`, `$$name`, `$$path`, `$$delim`, `$$version`, `$$line`, `$$col`, `$$tag`, `$$data`


### 2.3 Three-Tier Namespace
| Syntax | Meaning | Example |
| --------------- | --------------- | --------------- |
| `$member <block> <fieldname>` | structural field access    | `$member point x` |
| `$member <expr> $<property>`  | user-defined property      | `$member mod $PI` |
| `$member <expr> $$<meta>`     | language-injected metadata | `$member $file $$path` |

---

## 3. Type Lattice

morphl's type system has a well-defined top and bottom
```
         ()                   ← universal unit/void — top of value types
          |
         {}                   ← top of block hierarchy — empty block
        /    \
  blocks   primitives   unions  ← value kinds
        \    /    /
           $never              ← bottom — subtype of all types
```

### 3.1 `$never` - Bottom Type 

`$never` is the type of expressions that **never produce a value** because execution never continues past them. It is a subtype of every type:

```
$never <: for all types T
```

All control flow escapes have type `$never`:

| Expression | Type | Reason |
| --------------- | --------------- | --------------- |
| `$break` | `$never` | redirect to loop exit |
| `$continue` | `$never` | redirects to loop condition |
| `$ret <expr>` | `$never` | redirect to function return |
| `$exit <code>` | `$never` | redirect to process exit |

Since `$never <: T` for all `T`, control flow escapes unify cleanly with any branch type:

```
$decl x $if cond 
    10              // type: int
    $break;         // type: $never
// x : int
```

`$never` as a type annotation marks functions that never return:

```
$decl loop_forever $forward $func () $never; 
```

`$union T $never` collapses to `T` - `$never` contributes no inhabitants.

Implementing a trait on `$never` is meaningless - no value of type `$never` can ever exist.

### 3.2 `()` - Universal Unit / Void

`()` or `$group` with 0 argument, are the empty group - the universal unit/void type. It arises naturally from the group construct:

- A group `(a, b, c)` packs multiple expressions together
- A single-element group `$group x` collapses to `x` - no semantic difference
- Therefore an empty group `()` has zero elements - zero bytes, no meaningful value 

`()` is **universal** - it is not tied to block world. It means "no meaningful value" across all type kinds. It appears as:

- Return type of void functions: `$decl f $func () ()`
- No-argument function `$decl f () {...}`
- The absence of any value universally

### 3.3 `{}` Empty Block / Block Supertype

`{}` is the empty block - the top of the block type hierarchy. It is the supertype of all block types via prefix matching - every block has `{}` as a trivial prefix:

```
{ x: str, y: f64 } <: {} // any block satisfies empty block
```

`{}` is analogous to C's forward-declared struct - a block shape with no fields. It is the most generic block type: a function accepting `{}` accepts any block.

### 3.4 Relationship Between `()` and `{}`

`()` and `{}` are both zero-byte but distinct:

| Type | Meaning | Scope |
| --- | --- | ---|
`()` | universal unit/void | all type kinds |
`{}` | empty block / block supertype | block world only |


`()` is more general — it subsumes `{}`:

```
() <: {}    // () satisfies empty block — both zero bytes, () is more general
{} </: ()   // {} is specifically a block — not universal
```

In practice: use `()` for void returns and no-arg functions. Use `{}` when you mean "any block" as a type constraint.

---

## 4. Core Construct: `$decl`

### 4.1 Declaration as Binding of Storage

`$decl` is the single construct for introducing a named entity into a scope. It does not perform allocation or execution — it captures (pins) a storage described expression into the current scope.

```
$decl <name> <storage-expr>;
```

`$decl` contributes three things to the enclosing block:

- The **name** of the field
- The **type**, inferred from the storage expression
- The **byte offset** in the block's layout, determined by declaration order with natural alignment

### 4.2 Storage Driven Semantics

The behaviour of `$decl` is entirely determined by the storage expression. `$decl` itself is a pure declaration — it does not imply mutability, indirection, or any particular runtime behavior. The storage expression describes the semantics of the declared field.

### 4.3 Structural Shape Contribution

A `$decl` has three distinct properties:

- whether it contributes to the **structural shape**
- whether it contributes to the **instance layout**
- where the bound storage ultimately resides

Structural shape is about which named members a value exposes. Instance layout is about which bytes are stored in each instance.

Examples:
| Storage | Shape? | Layout? | Residence |
| --- | --- | --- | --- |
| `$const <expr>` | yes | yes | instance |
| `$mut <expr>` | yes | yes | instance |
| `$ref <lvalue>` | yes | yes | instance-held reference |
| `$extern ...` | yes | yes | instance-held external binding |
| `$static <expr>` | no | no | static/global |
| `$import "file"` | yes | yes | instance-held module binding |

> Structural type is derived from declarations whose bindings are exposed as members, not only from declarations whose targets live directly in the instance frame.

### 4.4 Expression Lifetime and Pinning

Expressions in morphl are **ephimeral** by default.

An expression has no lifetime until it is captured by `$decl`.

```
$add 1 2;  // ephimeral expression — no storage, no lifetime, cannot be referenced
$decl x $add 1 2;  // x = 3, lifetime pinned by $decl, can be referenced
```

### 4.5 `$alias` - Expression Substitution Binding

```
$alias <name> <expr>;
```

`$alias` introduces a **compile-time expression binding.**

**Properties**:

    - No storage
    - No capture
    - No lifetime extension
    - No contribution to block shape
    - No participation in runtime layouts

Each use of `<name>` resolves to `<expr>`.

```
$alias x $add 1 2;
$add x x;    // expands to: $add ($add 1 2) ($add 1 2)
```

When the aliased expression is an `$import`, the same rule applies: the alias substitutes the usage site with the import expression itself. It does **not** inline the imported file textually, and it does not introduce storage or shape into the current scope:

```
$alias io $import "stdlib/io.mpl";
$call $member io println ("hello");
// equivalent to:
$call $member ($import "stdlib/io.mpl") println ("hello");
```

`$alias` itself does not create a runtime binding. When an aliased expression is materialized into an unnamed runtime site, that site may still receive a compiler-generated lexical name such as `$anon$0` for diagnostics and debugging.

#### 4.5.1 `$alias` vs `$decl`

| Feature | `$alias` | `$decl` |
| --- | --- | --- |
| Storage | none | required |
| Lifetime | none | pinned to scope |
| Runtime presence | no | yes |
| Shape contribution | no | yes (if instance-resident) |
| Substitution | compile-time | no |

> `$alias` operates at the **expression layer**  \
> `$decl` operates at the **storage layer**



### 4.6 Block as Value

A block delimited by `{}` is both a struct and a code block — they are the same construct. Statements inside a block are initialization logic. The block's **type** is the structural shape of its surviving `$decl` expressions.

```
$decl x {
    $decl a $mut 10;
    $set a $add a 1;
};
// type of x: { a: i64 }
// a = 11 at capture time
```

`$decl` **suspends** the expression — the block executes once at declaration site and captures its final state. Referencing `x` later does not re-execute the block.

### 4.7 `$defer` — Deferred Cleanup

```morphl
$defer <expr>
```

`$defer` means: run `<expr>` after the current block goes out of scope.

- `$defer` has type `()`
- `$defer` contributes no structural shape
- deferred expressions execute in reverse lexical order (LIFO)

For an ordinary lexical block, the compiler lowers `$defer` to explicit unwind code for that block. This unwind runs when execution leaves the block by fallthrough or by a control-flow escape that exits the block.

When a block's lifetime is extended by capture, the defer list follows the lifetime of that captured block instance:

- block captured by `$decl` — defers run when the binding goes out of scope
- block captured by `$static` — defers run on normal program termination
- block captured and then moved to `$heap` — defers run when `$free` releases the allocation

For `$static`, "normal program termination" means the program reaches the end of top-level execution. Immediate `$exit` does not guarantee static deferred cleanup in v1.

For heap-backed captured blocks, the implementation attaches a compiler-generated cleanup thunk to the allocation. `$free` invokes that thunk exactly once before releasing the allocation.

Deferred actions are runtime behavior of the block instance, but they are not structural members and do not participate in the block's type.

`$defer` does not duplicate through ordinary value copying. Copying a block value copies the current value, not a second independent cleanup schedule. A fresh defer schedule is created only by constructing a fresh block instance, such as via `$new`.

### 4.8 Instantiation via `$new`

`$new` is a universal instantiation operator. It accepts any type expression and an optional initializer:

```
$new <TypeExpr>                 // 1-arg: re-execute block's init logic (fresh instance)
$new <TypeExpr> <initializer>   // 2-arg: create instance with field overrides
```

**1-arg form** — re-executes a block's initialization logic to produce a fresh, independent instance:

```
$decl p $new x;    // fresh instance, a = 11, independent of x
$decl q $new x;    // another fresh instance, independent of p
```

Mutating `p.a` does not affect `q.a`.

**2-arg form** — creates an instance of any type and applies an initializer before running the block body. Works for any type including scalars (redundant but valid since morphl is structural):

```
$decl y $new 0 55;                          // scalar: $new int 55 → y = 55

$decl p $new Point (3, 4);                  // positional group: x=3, y=4
$decl p2 $new Point { $decl x 3; $decl y 4; }; // named block init

$decl Circle { $decl r 0; };
$decl Rect   { $decl w 0; $decl h 0; };
$decl Shape  $union Circle Rect;
$decl s $new Shape Circle;                  // union init: tag auto-injected
```

The initializer can be:
- A **positional group** `(v1, v2, ...)` — values assigned to fields in declaration order
- A **named block** `{ $decl field val; ... }` — only named fields are overridden; unspecified fields use their declared defaults
- Any expression whose type is structurally compatible with the base type

**Union instantiation**: when the base type is a union, the compiler determines which variant the initializer belongs to via structural subtype check, and automatically injects the `$$tag` value. The tag is invisible in user code — it is always set by the compiler at construction time.

---

## 5. Storage Expressions

A **storage expression** is an expression that describes a concrete storage behavior.

Only storage expressions can be used as RHS of `$decl`.

### 5.1 `$const` — Immutable Storage

```
$const <storage-expr>
```

Marks the storage expression as immutable.

```
$decl x $const 10;   // x is an immutable int with value 10
$decl x $const $ref y;   // x is an immutable view to y (mark the reference bridge as immutable, therefore, only permit read access through x, even if y is mutable)
```

### 5.2 `$mut` — Mutable Storage

```
$mut <storage-expr>;
```

Marks the storage expression as mutable. Its value can be changed via `$set` later. The mutability of a field is part of its type and cannot be changed after declaration.

```
$decl x $mut 10;   // x is a mutable int with initial value 10
$decl x $mut $ref y;   // x is a mutable view to y (mark the reference bridge as mutable, therefore, permit write access through x, will fail if y is immutable)
```

#### **`$set` — Mutable Assignment**

`$set` writes a new value to a mutable storage location. The LHS can be a plain identifier or a compound lvalue:

```
$set x 10;                      // simple variable

$decl p { $decl x $mut 0; };
$set $member p x 42;            // block field
$set $member s $$tag 1;         // union tag (manual, bypasses type safety)

$decl arr $mut $array 0 4;
$set $index arr 2 99;           // array element (literal index)
$decl i 2;
$set $index arr i 77;           // array element (runtime index)
```

Only `$mut`-declared variables and fields may appear on the LHS of `$set`. Assigning to a `$const` binding is a compile error.

### 5.3 `$inline` - Non-Storage Expression

```
$inline expr;
```

Marks an expression as **non-storage**

**Properties**:

- Does not allocate storage

`$inline` can be used via `$alias` to create reusable non-storage expressions:

```
$alias zero $inline 0;   // zero is a reusable non-storage expression

$decl x $mut zero;       // valid — zero is consumed by $mut, which allocates storage for x
```

> Using `$inline` directly with `$decl` will treat it as a bare expression and implicitly lift it into constant ephemeral storage, so `$inline` is effectively ignored in that context:

```
$decl x $inline 10;   // $inline is ignored, x is a constant int with value 10 (not a non-storage expression)
```

#### Inlining functions

`$call` has a special interaction with `$inline` — if the callee is an `$inline` expression, the call is inlined at compile time:

```
$alias add_one $inline $func ($decl n 0) 0 {
    $add n 1
};
$decl x $call add_one 5;   // inlined to: $decl x $add 5 1
```

### 5.4 `$ref` — Reference

```
$decl r $ref <lvalue>
```

`$ref` is a typed handle to an existing storage location. It is morphl's uniform indirection mechanism across storage classes such as stack, static, heap, and future storage regions. `$ref` does not own the referent; it only provides access to existing storage.

In the current VM backend, local and static references are represented as 8-byte address-like handles. Other storage classes may use different backend encodings while preserving the same source-level semantics.

`$ref` is transparent in expressions — using `r` in an expression reads/writes through to the target's storage. The `$ref` keyword is only needed when explicitly bridging to the reference itself.

Using mutability storage descriptors on `$ref` describes access through the reference, not the reference slot itself, the mutability descriptor will not return the reference bridge as-is, instead, it will return a reference as an instance so that preceding mutability descriptor can apply to the reference's storage:

```
$decl r $mut $ref x;   // r is a mutable view to x — allows read/write access through r, but r itself is immutable (cannot reassign r to point to something else)
$decl r2 $const $ref x; // r2 is a read-only view to x — allows read access through r2, but no write access, and r2 itself is immutable (cannot reassign r2 to point to something else)

$decl r3 $mut $mut $ref x; // r3 is a mutable view to x, allows read/write access through r3, and r3 itself is mutable (can reassign r3 to point to something else)
$decl r4 $const $mut $ref x; // r4 is a mutable view to x, allows read/write access through r4, but r4 itself is immutable (cannot reassign r4 to point to something else)

// and so on...
```

Using `$ref` without a preceding mutability descriptor defaults to an immutable view:

```
$decl r $ref x;   // r is a read-only view to x — allows read access through r, but no write access, and r itself is immutable (cannot reassign r to point to something else)
```

**General lvalue operand**: `$ref` accepts any addressable lvalue — not just plain identifiers:

```
$decl arr $array 0 4;
$decl elem $ref $index arr 2;     // reference to arr[2]

$decl p { $decl x $mut 0; };
$decl fx $ref $member p x;        // reference to field x of block p

$decl circ $ref $as s Circle;     // reference reinterpreted as Circle (no extra offset)
```

Compound lvalue offsets are resolved entirely at **compile time** when the referent layout is statically known — no additional address computation is emitted at runtime in those cases.

**Nullability**: `$null` is valid for all `$ref` values.

**Equality**: two `$ref` values are equal when they denote the same storage slot.

**Rebinding**: assignment to a mutable reference slot rebinds the reference itself; assignment of a non-reference value writes through to the current referent.

```morphl
$decl x $mut 1;
$decl y $mut 2;

$decl r $mut $mut $ref x;
$set r $ref y;   // rebind r to point at y
$set r 3;        // write through r into y
$set r $null;    // rebind r to the null reference
```

Rebinding is valid only when the reference slot itself is mutable and the new target satisfies the reference's access requirements. Rebinding may cross storage classes at the language level as long as the referent type and access rules remain compatible.

**Lifetime rule**: a `$ref` must not outlive its target unless the target's storage class guarantees that lifetime. The compiler does not enforce this in v1.0 — it is a programmer responsibility. Storing a `$ref` to storage that is subsequently invalidated results in undefined behavior.

### 5.5 Mutability Subtyping

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

**`$mut` ref is a subtype of `$const` ref** — a mutable reference may be passed wherever a read-only reference is expected:

```
$mut $ref T <: $const $ref T     // safe — restricts write access at the call site
$const $ref T </: $mut $ref T    // unsafe — would grant write access to immutable storage
```

This rule is enforced by the type checker for function arguments, `$set` targets, and `$decl` initializers.

### 5.6 `$extern` — Native Symbol Binding

`$extern` is a storage expression that binds an instance-held slot to a native C symbol resolved at load time.

Supported forms:

```
$extern <type-expr>
$extern <string> <type-expr>
$extern <string>
```

Semantics:

- `$extern <type-expr>` uses the enclosing declaration name as the native symbol name
- `$extern <string> <type-expr>` uses the explicit symbol name and explicit type
- `$extern <string>` uses the explicit symbol name and requires the type to be known from context, for example from `$forward` or assignment target type

Unlike `$import` and `$static`, `$extern` contributes to both structural shape and instance layout. The instance stores the external binding handle/value; the bound target lives in native space.

**Native function binding** — the most common form:

```
$decl println   $extern $func ($decl s "") 0;   // (string) → i64
$decl print_int $extern $func ($decl n 0) 0;    // (i64)    → i64
$decl writer    $extern "println" $func ($decl s "") 0;
```

The `$func` expression is used only for its type; its body is not emitted. The VM stores a function table index in the declared slot; at call time the dispatcher invokes the native C function pointer instead of interpreting bytecode.

**Late binding after a forward declaration**:

```
$decl writer $forward $extern $func ($decl s "") 0;
$decl writer $extern "println";
```

**Rebinding a mutable extern**:

```
$decl writer $mut $extern "print" $func ($decl s "") 0;
$set writer $extern "println";
```

**Native constant binding** (v2 — via `dlsym`):

```
$decl ERRNO $extern 0;
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

### 5.7 `$static` - Static Storage Transformer

```
$static <storage-expr>
```

Move the storage described by `<storage-expr>` into **program-lifetime storage**.

**Semantics**:
- Storage exists in global/static region
- Not part of the block's structural shape
- Static identity is determined by lexical binding path, not by local name alone

```
$decl counter $static $mut 0;   // a static mutable counter
```

**Properties**:
| Property | Description |
| --- | --- |
| Lifetime | program lifetime (static storage) |
| Storage Location | owning file scope's `$$statics` namespace |
| Shape Contribution | none — does not affect block's structural type |
| `$new` inheritance | no — static fields are not inherited by new instances |

#### 5.7.1 Lexical Static Identity

Each `$static` declaration is keyed by its **lexical path** under the owning file scope's intrinsic `$$statics` block.

- Named scopes contribute their declared name
- Unnamed scopes contribute `$anon$N`, in lexical order within the parent scope
- The declaration name is the final path segment

Examples:

```
$decl x $static $mut 0;
// binds to: $file.$$statics.x
// and, in the source file: $global.$source.$$statics.x

$decl f1 $func () {
    $decl x $static $mut 0;
};
// binds to: $file.$$statics.f1.$anon$0.x
```

This rule prevents collisions between same-named local statics in different scopes and gives unnamed runtime sites a stable canonical name for diagnostics/debugging.

For imported modules, the same rule is rooted in the imported file scope, so a static declared in module binding `mod` is inspectable through `$global.$modules.mod.$$statics...`.

#### 5.7.2 Initialization

`$static` storage is initialized at most once for each lexical binding path.

- top-level statics initialize when their declaration executes
- function-local statics initialize on first execution of that declaration
- subsequent executions reuse the same slot without re-running the initializer


```
$decl counter $static $mut 0;   // a static mutable counter

$decl y $static 42;
$decl direct $member $member $file $$statics y;

$decl f $func () {
    $decl b $static $mut 100;
    $set $member $member $file $$statics b
         $add $member $member $file $$statics b 1;
    $ret $member $member $file $$statics b;
};
```

`$file.$$statics...` is the ergonomic authoring path inside a file. `$global.$source.$$statics...` and `$global.$modules.<name>.$$statics...` are the corresponding global inspection paths.

Since `$static` fields contribute no shape to the block, they are not inheritable via `$new`:

```
$decl Foo {
    $decl a 0;
    $decl b $static 42;   // static field — not inherited by new instances
};

$decl f1 $new Foo;     // f1 has only field a, no b

$member f1 a;  // valid
$member f1 b;  // error — b is not part of f1's shape
```

### 5.8 Bare Expression as Storage

A bare expression in storage-expression context is treated as a constant ephemeral storage expression.

So expression like:
```
0
$func () { ... }
"Hello"
```
are implicitly lifted into constant ephemeral storage.

Therefore, using a bare expression as the RHS of a `$decl` works:

```
$decl x 0; 
```

### 5.8 Storage Expression Summary

| Expression | Meaning | Writable |
|---|---|---|
| `$const expr` | immutable storage | no |
| `$mut expr` | mutable storage | yes |
| `$ref lvalue` | alias to any addressable lvalue | depends on referent |
| `$static expr` | static storage (program lifetime) | depends on wrapped storage |
| `$inline expr` | non-storage expression, must be consumed by storage specifier | no |
| `$new T` | fresh instance via re-execution of block T | depends on fields |
| `$new T init` | instantiate T with initializer (any type) | depends on fields |
| `$import "file"` | module-loading expression; when pinned by `$decl`, yields an instance-held module binding | depends on mutability wrapper |
| `$extern <type-expr>` | native symbol binding, default symbol name from declaration | depends on mutability |
| `$extern <string> <type-expr>` | native symbol binding with explicit symbol name and type | depends on mutability |
| `$extern <string>` | native symbol binding with explicit symbol name and contextual type | depends on mutability |
| bare `expr` (in storage expression context only) | implicitly lifted into constant ephemeral storage | no |

---

## 6. Structural Type System

### 6.1 Types Are Implied by Declaration Shape

There are no explicit type annotations for structs. A type is the set of field names and their storage kinds as declared:

```
$decl point {
    $decl x $mut 0;
    $decl y $mut 0;
};
// type: { x: $mut i32, y: $mut i32 }
```

> The structural type of a block consists only of `$decl`s whose storage resides in the instance frame.

This excludes:
- `$static`
- `$extern`
- future non-instance storage specifiers

### 6.2 Structural Subtyping

Two types are compatible if one's fields are a prefix match of the other's at identical byte offsets. A type `A` is a structural subtype of `B` if every field in `B` exists in `A` at the same offset with a compatible type.

```
$decl Animal {
    $decl age 0;
    $decl weight 0.0;
};
$decl Dog {
    $decl age 0;
    $decl weight 0.0;
    $decl name $ref age;  // $ref — fixed 8 bytes regardless of referent size
};
// Dog <: Animal — prefix matches, offsets identical
```

### 6.3 Struct Layout

Fields are laid out in **declaration order with natural alignment**. Padding is inserted to align each field to its own size. This guarantees stable, predictable offsets across all implementations — the foundation of structural subtyping across module boundaries.

```
$decl Foo {
    $decl a 0;      // offset 0  (8 bytes — all integers are i64)
    $decl b 0.0;    // offset 8  (8 bytes — f64)
    $decl c 0;      // offset 16 (8 bytes — i64)
};
// total: 24 bytes
```

> **Note**: In the current implementation all scalar types (integers, floats, booleans, strings, references) occupy 8 bytes on the frame stack. The alignment of each is 8, so no padding is inserted between scalars of the same size. Padding is inserted before a field whose alignment exceeds the current offset — for example a `$ref` (8-byte aligned) following a hypothetical 1-byte field.

Fields are **never reordered** by the compiler. Reordering would break the prefix-match subtyping guarantee.

### 6.4 Recursive Types via `$ref`

Direct recursive fields are impossible because the type has no finite size:

```
$decl Node { $decl value 0; $decl next Node; };  // error — infinite size
```

`$ref` breaks the cycle by storing a fixed-size handle regardless of the referent's size:

```
$decl Node {
    $decl value 0;
    $decl next $ref Node;   // fixed size handle in the current backend
};
```

### 6.5 `$null`

`$null` is the universal null reference sentinel. It is valid for every `$ref` type and indicates "this reference points to nothing." Dereferencing `$null` traps at runtime in the current VM backend.

**Concrete representation**: in the current VM backend, `$null` is stored as the address-like handle `0`. The `RNULL` opcode pushes `0`. `DEREF` traps at runtime if it encounters `0` (address 0 is never a valid frame address — frame slot 0 is reserved for `$parent`). `JNULL` branches when the top of stack equals `0`.

---

## 7. Union Types

### 7.1 `$union` - Inline Union 

`$union` composes any set of types into a structural union. It is a variadic prefix expression consistent with other compound type builtins:

```
$union <type-expr>*

$union Cstr Slice       // two-variant union 
$union 0 0.0 ""         // three-variant union (int, float, string)
$union 0 $null          // nullable int - option type
```

`$union` is structural and open - any type structurally compatible with a variant can inhabit the union. This differs from a closed nominal sum.

Naming a union via `$decl`:

```
$decl StringType $union CStr Slice;
$decl Option    $union 0 $null;
$decl Result    $union { $decl value 0; } { $decl err ""; }
```

### 7.2 Memory Layout

Data first, then the tag at the end. This allows `$as` and prefix subtyping to work seamlessly directly on the union variable (no intermediate `$$data` access required):

```
$union CStr Slice:
    offset 0                        → $$data: max(sizeof CStr, sizeof Slice)
    offset max(sizeof CStr, sizeof Slice) → $$tag: i64 (8 bytes, compiler-injected)
```

Total size: `max_variant_size + 8`.

Because the payload starts at offset 0, a union variable can be directly reinterpreted as any of its variants without an intermediate address computation:

```
$decl c $ref $as s Circle;   // Circle fields start at s+0 — correct
```

`$$tag` is a language-injected field — readable by user code but invisible to the structural type system (uses `$$` reserved namespace). Its byte offset is `union_size - 8`, which is statically known from the union type.

### 7.3 Tag Assignment

Tags are assigned by the compiler based on variant order in the `$union` expression:

```
$union CStr Slice
// CStr  → $$tag 0
// Slice → $$tag 1
```

Tag assignment happens at the call site or assignment site when a concrete value enters a union — the compiler inserts the tag implicitly. If the concrete type matches multiple variants, first-match wins (consistent with grammar rule ordering).

**Manual tag write via `$set`**: the `$$tag` field can also be set explicitly using `$set` with a `$member` compound LHS:

```
$decl s Shape;
$set $member s $$tag 1;    // mark s as Rect (variant 1)
```

This bypasses type checking — the programmer is responsible for consistency between tag and data. Prefer `$new Shape variant` for safe construction.

### 7.4 Nested `$union` is Flat

Nested `$union` expressions are flattened:

```
$union 0 $union 0.0 ""    →   $union 0 0.0 ""
```

### 7.5 `$union` with `$never` and `()`

```
$union T $never   →   T          // $never contributes no inhabitants
$union T ()       →   T | unit   // T or nothing meaningful
```

### 7.6 Variant Tag Check 

Reading `$$tag` directly:

```
$decl Circle    { $decl radius 0.0 }
$decl Rect      { $decl width 0.0; $decl length 0.0 }
$decl Shape     $union Circle Rect;


$decl s $new Shape {$decl radius 3.0};
$if $eq 
    $member s $$tag
    $member $new Shape Circle $$tag {
        // s can be safely interpreted as Circle
        $decl circle $ref $as s Circle;
        ...
    }
```

!> [!NOTE]
> `$member $new <union> <expr> $$tag` is able to resolve statically even though `$new` keyword exists

### 7.7 `$$data` — Payload Access

`$$data` returns the address of the union's payload region. Because the layout is **data-first** (payload at offset 0), `$$data` is equivalent to the union variable's own address. Its type is `{}` (empty block — the structural top of the block hierarchy), which is a prefix supertype of every concrete variant:

```
$member s $$data          // → type: {}  (address of s, offset 0)
```

Thanks to data-first layout, `$as` can be applied directly to the union variable without going through `$$data` first:

```
$decl Circle    { $decl radius 0.0 }
$decl Shape     $union Circle;

$decl s $new Shape {$decl radius 3.0};
$if $eq $member s $$tag 0 {
    // s holds a Circle — both forms are equivalent:
    $decl c $ref $as s Circle;              // direct — preferred
    $decl c2 $ref $as $member s $$data Circle;  // explicit $$data — also valid
};
```

Both `$as s Circle` and `$as ($member s $$data) Circle` are safe and produce the same result: a reference into the union starting at byte 0, typed as `Circle`.

Accessing the payload without a preceding `$$tag` check is allowed but unsafe — the programmer asserts knowledge of the active variant.

### 7.5 `$overload` - First-Class Overload Aggregate

`$overload` stores multiple candidate expressions in one value:

```morphl
$overload <expr>+
```

It is a first-class aggregate value with group-like storage:

- one slot per candidate, in lexical order
- candidate selection happens at each use site during typing
- the compiler first tries the overload object itself when the surrounding
  context accepts overload type directly
- otherwise it tries candidates left-to-right and picks the first compatible
  candidate

Examples:

```morphl
$decl x $overload 0 0.0;
$add x 1;      // resolves x as int
$fadd x 1.0;   // resolves x as float

$decl y $mut $overload 0 0.0;
$set y 10;                   // writes int slot
$set y $overload 11 11.0;    // whole-object assignment
```

Overload type identity is positional and exact: two overload values have the
same type iff they have the same candidate count and each corresponding
candidate type is equal.

Whole-object operations such as `$set lhs rhs` may resolve both sides as
overload objects directly. If whole-object compatibility fails, typing falls
back to candidate projection.

> **Implementation status**: the VM pipeline supports stored source-level
> `$overload` values, candidate projection, and whole-object assignment. The C
> backend currently rejects source-level `$overload`. Lazy `$inline $overload`
> behavior is not yet implemented.

---

## 8. Array Types 

### 8.1 `$array` - Fixed-Size Array 

`$array` is a storage expression allocating a contiguous sequence of `N` elements of type `T`:

```
$decl buf $array 0 4;       // 4 * i32 = 32 bytes, stack allocated (8-byte VM slots)
$decl mat $array 0.0 9;     // 9 * f64 = 72 bytes
```

The element type is inferred structurally from the first argument expression:

```
$decl zero 0;
$decl buf $array zero 4;    // element type inferred as int from zero
```

Type signature: `[T * N]` — size is part of the type. Two arrays of different sizes are different types:

```
[i32 * 4] != [i32 * 8]
```

Array subtyping is exact match only — no prefix subtyping for arrays in V1. The frame slot is stack-allocated and zero-initialized at scope entry.

### 8.2 Element Access via `$index`

`$index array i` reads element `i` from the array. Both literal and runtime indices are supported:

```
$decl buf $array 0 4;
$decl first $index buf 0;   // reads buf[0] — literal index: offset computed at compile time
$decl third $index buf 2;   // reads buf[2]

$decl i $mut 1;
$decl elem $index buf i;    // reads buf[i] — runtime index: offset computed at runtime
```

For **literal indices**, the byte offset is computed entirely at compile time: `offset = array_frame_offset + i * element_size`.

For **runtime indices**, the VM computes the address at runtime: `base_address + index * element_size`. Out-of-bounds checking is not performed in V1 — the programmer is responsible for ensuring valid indices.

### 8.3 Element Assignment via `$set $index`

Array elements can be assigned via `$set` with a compound `$index` LHS:

```
$decl buf $array 0 4;
$set $index buf 2 99;       // buf[2] = 99 (literal index)

$decl i 1;
$set $index buf i 77;       // buf[i] = 77 (runtime index)
```

### 8.4 Summary Table

| Expression | Meaning | Type |
|---|---|---|
| `$decl buf $array T N` | allocate `N` elements of type `T` | `[T * N]` |
| `$index buf i` | read element `i` (literal or runtime) | `T` |
| `$set $index buf i val` | write `val` to element `i` | — |

---

## 8.5 Compiler-Injected Intrinsic Properties

Three universal `$$`-prefixed pseudo-fields are available on any expression via `$member`. They resolve entirely at **compile time** — the target expression is **not evaluated at runtime** (analogous to C's `sizeof`).

| Syntax | Return type | Value |
|---|---|---|
| `$member <expr> $$name` | `string` | Identifier name of `<expr>`, or `""` if not a plain identifier |
| `$member <expr> $$size` | `int`    | Size in bytes of `<expr>`'s type |
| `$member <expr> $$type` | `string` | Type signature of `<expr>` as a string |

### Examples

```
$decl x 42;
$member x $$name          ; → "x"
$member x $$size          ; → 8       (i64 is 8 bytes)
$member x $$type          ; → "int"

$decl Point { $decl px 0; $decl py 0; };
$decl p $new Point ();
$member p $$name          ; → "p"
$member p $$size          ; → 16      (two i64 fields)
$member p $$type          ; → "{px:int, py:int}"

$member (42) $$name       ; → ""      (literal, not an identifier)
$member (42) $$size       ; → 8
$member (42) $$type       ; → "int"
```

### Notes

- These intrinsics work on any type: primitives, blocks, unions, arrays, functions, references.
- Because the target is not evaluated, `$member ($call sideEffect ()) $$size` does **not** call `sideEffect` — only its return type is inspected.
- `$$name` returns `""` for any non-identifier expression (calls, arithmetic, literals, etc.).
- The type string format from `$$type` matches the internal type signature format (same as used in error messages).

---

## 9. `$as` — Reinterpret Cast

`$as` is a general-purpose reinterpret cast. It changes the compiler's view of a value's type without emitting any runtime code:

```
$as <expr> <type>
```

`$as` is the morphl equivalent of C's `reinterpret_cast`. No bits are moved or converted — only the type annotation changes. The programmer is responsible for ensuring the reinterpretation is safe.

### 9.1 Primitive reinterpretation

```
$decl x 42;
$decl y $as x 0.0;    // view the int bits as float — unsafe, but allowed
```

### 9.2 Union variant narrowing (safe pattern)

The idiomatic safe use of `$as` is narrowing a union variable to a known variant type after a `$$tag` check. Because unions use **data-first layout** (payload at offset 0), `$as` can be applied directly to the union variable:

```
$decl Shape $union Circle Rect;
$decl s $new Shape {$decl radius 3.0};

$if $eq $member s $$tag 0 {
    // tag 0 = Circle variant
    $decl circle $ref $as s Circle;
    // circle is a Circle reference into s, starting at byte 0
};
```

This pattern is safe because:
1. The `$$tag` check guarantees the active variant.
2. `$as` annotates the type without generating code.
3. `$ref` creates a reference to `s`'s frame slot (byte 0 = start of Circle data).
4. Prefix subtyping holds: `Circle <: {}`, so the reinterpretation is layout-compatible.

`$as ($member s $$data) Circle` is also valid and produces the same result.

### 9.3 Unsafe uses

Using `$as` without a preceding `$$tag` check is allowed but unsafe — the programmer asserts knowledge of the active variant.

### 9.4 Type resolution

The second argument to `$as` is any expression. Its inferred type becomes the cast target — the same structural inference used by `$decl` and all other keywords. No special type-keyword names are recognised; use a literal or variable of the desired type.

---

## 10. Functions

### 9.1 `$func` Declaration

Functions are first-class values declared with `$func`. The argument list is a **pseudo-scope** pasted before the function body in the scope chain:

```
$decl f $func ($decl x 0) {
    $decl y $add x 1;
};
// type: (i64) => { y: i64 }
```

### 9.2 Argument Pseudo-Scope

Arguments live in a scope outside the function body. They are readable inside the body via scope resolution but are **not captured** into the body's structural type. Arguments are caller-owned and cleaned up by the caller (cdecl convention).

### 9.3 Return Semantics

**Implicit return** — if no `$ret` is used, the entire function body is the return value. Its type is the structural shape of the body's captured declarations:

```
$decl make_point $func ($decl x 0, $decl y 0) {
    $decl px x;
    $decl py y;
};
// type: (i64, i64) => { px: i64, py: i64 }
```

**Explicit return** — `$ret expr` returns a specific value and exits the function early. An explicit operand is always required:

```
$decl f $func ($decl x 0) {
    $ret $add x 1;   // return i64
};
// type: (i64) => i64

$decl g $func () {
    $ret ();      // explicit void return — $ret () is the canonical form
};
// type: () => ()
```

`$ret` is scoped to the nearest enclosing `$func`. It does not propagate through nested blocks.

**Mixed paths** — if some code paths use `$ret` and others rely on implicit return, the types must unify. A compile error is emitted if they do not.

### 9.4 Encapsulation via `$ret`

`$ret` is the sole encapsulation mechanism. Without it, all declarations in the body are exposed in the return type. With it, only the explicitly returned value is exposed:

```
$decl f $func ($decl x 0) {
    $decl result $add x 1;
    $decl tmp 999;       // implementation detail
    $ret { $decl result result };     // only result is exposed
};
// type: (i64) => { result: i64 }
```

### 9.5 `$exit` — Explicit Process Exit

`$exit` terminates the process immediately with a given integer exit code:

```
$exit 0;      // exit with code 0 (success)
$exit 1;      // exit with code 1
$exit code;   // exit with value of 'code' (must be i32)
```

Rules:
- An explicit exit code is always required. `$exit 0;` is the canonical success exit.
- The argument must be of type `i64` (integer). Any other type is a compile error.
- `$exit` can appear anywhere in top-level code or inside a function.
- `$exit` is immediate in v1 and does not guarantee deferred cleanup for longer-lived static bindings.

### 9.6 Program Entry

Program execution begins at top-level code.

- Top-level statements execute in source order.
- `$exit expr` terminates execution immediately with the given exit code.
- If top-level execution reaches the end without `$exit`, the VM exits with code `0` on `HALT`.
- A declaration named `main` has no implicit entrypoint behavior. It is an ordinary binding unless a future build configuration explicitly selects it as an entry symbol.

Example:

```
$decl helper $func () {
    $ret 7;
};

$exit $call helper ();
```

### 9.7 Function Type Signature

```
(<arg-types>) => <return-type>
```

Functions are contravariant in argument types and covariant in return type for subtyping purposes.

### 9.6 Calling Convention

The caller pre-allocates the return slot before the call. The body writes directly into the return slot (sret convention for struct returns). On `$ret` or end of body, the pseudo-scope is discarded — the return value is already in place with no copy needed.

Stack layout at call time:

```
| caller frame               |
| return slot                |  ← pre-allocated by caller
|----------------------------|
| pseudo-scope (args)        |  ← pushed at call, popped after
| function body              |  ← writes to return slot directly
```

### 9.7 Function Table

All functions are entries in a global function table. A function value at runtime is a `u32` index into this table. This makes function pointers relocatable and safe — no absolute addresses, no forgeable indices.

```
FuncTable[n] = { bytecode_offset, arity, frame_size }
```

---



## 11. Control Flow

### 11.1 `$if` — Conditional Expression

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

**Type of `$if`**: the result type is determined by joining the branch types:

| Branches | Result type |
|---|---|
| No else branch | `void` — `$if` is used for side effects only |
| Then = `$never` | Type of the else branch |
| Else = `$never` | Type of the then branch |
| Both same type | That type |
| Different types | `$union(then_type, else_type)` |

```
$decl x $if cond 10 20;          // int — both branches int
$decl y $if cond 10 { $break; }; // int — else is $never, y : int
$if cond { $set x 1; };          // void — no else branch
```

### 11.2 `$while` — Loop

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
- **Type of `$while`**: always `void`. `$while` is always used for its side effects; it never produces a meaningful value.


### 7.3 `$break` and `$continue` — Loop Control

`$break` exits the nearest enclosing `$while` immediately.

`$continue` skips the remainder of the current iteration and re-evaluates the loop condition.

Both have type of `$never`

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

## 12. Scope Contexts

Every scope maintains a set of reserved context references. These are `$ref`-based — relative offsets following the same semantics as user-defined references.

| Reference | Meaning |
|---|---|
| `$this` | the current block instance |
| `$parent` | the enclosing block instance |
| `$file` | the current file's scope |
| `$global` | the root/global scope |
| `$member $global $parent` | `$null` — root has no parent |

`$this` refers to the immediate scope, not any outer scope. Inside a function body, `$this` is the function's own block, not the enclosing module.

```
$decl mod {
    $decl x 0;
    $decl f $func () {
        $this;               // f's own body — { }
        $parent;             // mod's instance
        $member $parent x;  // mod's x field
    };
};
```

The scope chain is a `$ref`-linked structure terminating at `$member $global $parent = $null`. Traversal is uniform — the same machinery as user-defined `$ref` chains.

---

## 13. Properties

### 13.1 `$prop` Declaration

Properties are declared with `$prop` and accessed with the `$` prefix:

```
$decl mod {
    $decl x 0;
    $prop PI 3.14;
};

$member mod x;    // field access
$member mod $PI;  // property access
```

Properties are extra context attached to a block. They are constant once declared — they cannot be reassigned.

**Compile-time substitution**: property access via `$member mod $PI` is resolved entirely at compile time. The compiler substitutes the property's value expression directly — no runtime load is emitted. Property values must be constant expressions (literals, arithmetic on literals, etc.).

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
        $ret $member $parent x;
    };
};
```

---

## 14. Traits

Trait fat-block representation and dynamic dispatch are fully implemented. The `$traits`/`$impl` syntax is parsed, type-checked, and compiled to bytecode. Trait-typed variables use a 16-byte fat-block layout in the stack frame. Dynamic dispatch is performed via the `CALLX` opcode.

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
    $prop methodB $func () { $ret $member $parent x; };
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
$call ($member traitVar $methodB) ();
// Emitted sequence:
// 1. RESERVE  — allocate return slot
// 2. RLOAD traitVar+8  — push $parent = traitVar.$data (concrete instance)
// 3. [push arguments]
// 4. RLOAD traitVar    — load property table absolute address (traitVar.$impl)
// 5. ALOAD prop_idx*8  — load method function-table index from property table
// 6. CALLX             — dispatch by popping the function index from the stack
```

The property table is a singleton allocated in the global frame once per `$impl` declaration. Each slot holds a `u32` function-table index (stored as `i64`) for one trait property, ordered by property declaration index in the trait.

---

## 15. Modules and Imports

### 11.1 Files as Blocks

A file is a block. Its type is the structural shape of its top-level `$decl` expressions, augmented with compiler-provided intrinsics. `$file` is the reserved reference to the current file's scope.

Every `$file` scope has an intrinsic member:

```
$$statics
```

`$$statics` is compiler-owned and contains that file's static storage, keyed by lexical path. It is accessible from within the file as:

```
$member $file $$statics
```

and then by further `$member` access to specific static bindings.

The current source file is also exposed through:

```
$global.$source
```

so its statics are inspectable as:

```
$global.$source.$$statics...
```

### 11.2 `$import`

`$import` is a module-loading expression. Evaluating it ensures the target file is loaded and registered in `$global.$modules`, and the expression evaluates to the loaded module binding.

Imported module bindings expose the imported file's intrinsic members as well, including `$$statics`. This makes the module's static storage inspectable through `$global.$modules.<name>.$$statics...`.

Pinned with `$decl`, the resulting module binding becomes a real field:

```
$decl module $import "some_module";
$member module some_var;
```

Aliased with `$alias`, it remains a pure expression substitution and does not affect the scope's type or structure:

```
$alias module $import "some_module";
$member module some_var;
```

Inline import without binding:

```
$member ($import "some_module") some_var;
```

The imported module's type is structurally inferred from its file scope. No separate interface file or explicit export list is required — all top-level declarations are visible.

Conceptually:

- `$import "path"` mutates the module registry if needed and returns a module value
- `$alias name $import "path"` keeps that value at the expression layer only
- `$decl name $import "path"` pins that module value into storage as an ordinary declaration, so it contributes to structural shape and instance layout like any other declared field

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

## 16. Grammar System

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

- **Left-associative**: rhs binding power > lhs binding power
- **Right-associative**: rhs binding power <= lhs binding power
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

This internal grammar-template overload mechanism is distinct from the
source-level `$overload` keyword. Template alternatives produce a transient
`AST_OVERLOAD` selection node; source `$overload` creates a first-class runtime
value.

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

## 17. VM Opcode Set

The VM uses **typed opcodes** — the operand type and size are encoded in the opcode itself, not in the values. Values on the stack are raw bits with no runtime type tags.

### 13.1 Load / Store

```
ILOAD  <offset>    — load i64 from frame offset
FLOAD  <offset>    — load f64 from frame offset
RLOAD  <offset>    — load i64 reference handle ($ref) from frame offset
ISTORE <offset>    — store i64 to frame offset
FSTORE <offset>    — store f64 to frame offset
RSTORE <offset>    — store i64 reference handle to frame offset
```

### 13.2 Constants

```
ICONST <imm>       — push i64 literal
FCONST <imm>       — push f64 literal
RNULL              — push $null reference (absolute address 0)
```

### 13.3 Arithmetic

```
IADD  ISUB  IMUL  IDIV  IMOD   — i64 arithmetic
FADD  FSUB  FMUL  FDIV         — f64 arithmetic
```

### 13.4 Comparison

```
IEQ  INEQ  ILT  IGT  ILTE  IGTE   — i64 comparisons, push bool
FEQ  FNEQ  FLT  FGT  FLTE  FGTE   — f64 comparisons, push bool
REQ  RNEQ                          — reference equality (compare two i64 absolute addresses)
```

### 13.4a Bitwise

```
IBAND  IBOR  IBXOR          — i64 bitwise AND / OR / XOR  (binary)
IBNOT                       — i64 bitwise NOT  (unary)
ILSHIFT  IRSHIFT            — i64 left / right shift
```

### 13.5 Type Conversion

```
I2F    — convert i64 → f64
F2I    — convert f64 → i64 (truncate)
```

### 13.6 Scope / Block

```
ENTER  <size>      — push new scope region of <size> bytes
LEAVE  <size>      — pop scope region
```

When a scope contains lexical `$defer` expressions that are not captured into a longer-lived block instance, the compiler emits the deferred cleanup sequence before the corresponding `LEAVE`, in reverse lexical order.

### 13.7 Function Call

```
RESERVE <size>     — pre-allocate return slot in caller frame
CALL    <index>    — direct call by function table index
CALLF   <offset>   — indirect call: load function index from frame offset, then dispatch
CALLX              — dynamic dispatch: pop i64 function index from stack, then dispatch
RET                — pop pseudo-scope, return to caller
```

Each function table entry carries a `flags` field. When `flags & NATIVE` is set, `entry_point` is an index into the program's native function pointer array rather than a bytecode offset. The dispatcher invokes the C function pointer directly; `RET` is not executed — the native function returns via the normal C call stack and its `int64_t` return value is written to `stack[frame_base - 8]`.

### 13.8 Reference / Indirection

```
ADDREF  <offset>   — push the current backend's reference handle for frame[offset]
DEREF              — resolve a reference handle to its target location (traps on 0 in the current VM)
RNULL              — push $null (reference handle 0 in the current VM) as i64
JNULL   <label>    — jump if top of stack is 0 ($null reference)
PLOAD   <offset>   — load field from $parent frame at (parent_base + offset)
PSTORE  <offset>   — store field to $parent frame at (parent_base + offset)
```

### 13.9 Block Instantiation

```
NEW <offset> <size>   — re-execute block at <offset>, write result into <size> bytes
```

`NEW` is the only opcode that re-executes logic. It corresponds directly to `$new` in source.

> **Not yet implemented**: `NEW` opcode. `$new` currently emits `RESERVE` + `CALL` against a named deferred function; arbitrary block re-execution via offset is not yet supported.

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

`EXIT` is emitted by `$exit expr`. It unconditionally terminates the VM and propagates the exit code to the host OS.

### 13.12 Design Notes

- No GC opcodes — memory is stack-managed and explicit
- No type tag opcodes — types are encoded in instructions, not values
- `CALLX` enables dynamic dispatch for trait method calls — all other dispatch resolves statically
- No implicit copy opcodes — copies are explicit load/store pairs
- Function pointers are `u32` indices into the global function table

---

## 18. Type System Summary

| Layer | Mechanism | Participates in subtyping |
|---|---|---|
| Structural fields | `$decl`, fixed byte offsets | yes — prefix match |
| Properties | `$prop`, no fixed offset | no |
| Traits | `$traits` + `$impl` | via property table |
| Mutability | `$mut` / `$const` in field type | yes — `$mut <: $const` |
| References | `$ref`, fixed-size reference handle (8 bytes in the current VM) | yes — same as referent type |

---

## 19. Grammar Reference (Informal)

```
program     ::= decl*
decl        ::= '$decl' name storage-expr ';'
             |  '$prop' name expr ';'
storage-expr::= '$mut' expr
             |  '$const' expr
             |  '$static' expr
             |  '$ref' name
             |  '$new' expr
             |  '$import' string
             |  '$extern' expr
             |  '$extern' string expr
             |  '$func' '(' params ')' block
             |  '$traits' block
             |  '$impl' name name block?
             |  expr
block       ::= '{' stmt* '}'
stmt        ::= decl
             |  expr ';'
             |  '$ret' expr ';'
             |  '$exit' expr ';'
             |  '$defer' expr ';'
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

## 20. Resolved Design Decisions

The following questions were previously open; they are now settled.

**Implicit `$parent` in method calls** — when emitting `$call $member obj method args`, the caller pushes `$parent = &obj` as a hidden argument before the normal arguments, matching the existing calling convention (caller-owned, cleaned up after CALL). The VM emitter is responsible for inserting this push. This is consistent with the existing `$parent` slot at `frame[0]` inside every function body.

**`$null` representation** — `RNULL` pushes `0` as the null reference sentinel in the current VM backend. Address 0 is never a valid frame address since `frame[0]` is reserved for `$parent`. `DEREF` traps at runtime if it encounters `0`. `JNULL` branches when the top of stack equals `0`.

**Cross-storage `$ref` lifetime** — a `$ref` must not outlive its target unless the target's storage class guarantees that lifetime. This rule is not enforced by the compiler in v1.0; it is a programmer responsibility documented here. Violating it (e.g. storing a `$ref` to storage that is later invalidated) results in undefined behavior.

**`$mut` / `$const` on `$ref` fields** — the mutability qualifier on a `$ref` describes access through the reference, not storage of the reference itself:
- `$const $ref x` — read-only access through the ref, regardless of x's own mutability.
- `$mut $ref x` — read-write access through the ref, but only valid if x is itself `$mut`.
The ref's own storage is a fixed-size handle in the current VM backend. Slot mutability is still controlled separately by the outer mutability qualifiers; rebinding requires the reference slot itself to be mutable.

**Property table dispatch for `$parent`** — when a trait method is called through a fat trait variable, the emitted sequence is: (1) `RESERVE` the return slot, (2) `RLOAD traitVar+8` to push `$parent = traitVar.$data` (the concrete instance address), (3) push any call arguments, (4) `RLOAD traitVar` to load the `$impl` property table absolute address, (5) `ALOAD prop_idx*8` to load the method's function-table index from the property table, (6) `CALLX` to dispatch. The `$parent` slot at the callee's `frame[0]` then points to the concrete data instance, not the fat variable itself. `CALLX` pops the function index from the stack rather than reading it from a fixed frame offset, enabling runtime-resolved dispatch.

---

## 21. Operator Table

All built-in operators registered in `kBuiltinOps` (`src/parser/operators.c`). "Args" shows the min–max argument count; `∞` means unlimited.

| Operator | Args | Description |
|---|---|---|
| **Structural** | | |
| `$group` | 0–∞ | Tuple / unit group. 0 args = `()` (void unit). |
| `$block` | 0–∞ | Explicit block literal. |
| **Core Constructs** | | |
| `$decl` | 2 | Declare a named binding. Preprocessor action. |
| `$prop` | 2 | Declare a compile-time constant property on a block. Preprocessor action. |
| `$set` | 2 | Assign a value to a mutable binding. |
| `$call` | 2 | Call a function: `$call func args`. |
| `$func` | 2 | Function literal: `$func params body`. |
| `$if` | 2–3 | Conditional: `$if cond then [else]`. |
| `$while` | 2 | Loop: `$while cond body`. Result type is `{}`. |
| `$ret` | 1 | Return from function. `$ret ()` for void return. Explicit operand required. |
| `$exit` | 1 | Exit process. `$exit 0;` required (no bare `$exit`). |
| `$defer` | 1 | Schedule an expression to run when the current block instance goes out of scope. |
| `$break` | 0 | Break out of nearest loop. Type is `$never`. |
| `$continue` | 0 | Continue to next loop iteration. Type is `$never`. |
| **Member Access** | | |
| `$member` | 2 | Field or property access: `$member obj field`. Properties resolved at compile time. |
| **Storage Qualifiers** | | |
| `$mut` | 1 | Mark storage as mutable. |
| `$const` | 1 | Mark storage as immutable (default). |
| `$inline` | 1 | Inline storage qualifier (implementation extension). |
| **Reference** | | |
| `$ref` | 1 | Create a reference (fixed-size handle; 8 bytes in the current VM). |
| `$null` | 0 | Null reference (handle value 0 in the current VM). |
| `$new` | 1–2 | Re-instantiate a block: `$new Type [overrides]`. |
| **Scope / Context** | | |
| `$this` | 0 | Address of the current block. |
| `$parent` | 0 | Reference to the enclosing block. |
| `$file` | 0 | Current file's block. |
| `$global` | 0 | Global frame reference. |
| **Modules** | | |
| `$import` | 1 | Import a module by file path string. Preprocessor action. |
| `$syntax` | 1 | Switch grammar for the current block. Preprocessor action. |
| **Type System** | | |
| `$array` | 2 | Array type: `$array ElemType count`. |
| `$index` | 2 | Array element access: `$index arr i`. |
| `$union` | 1–∞ | Tagged union type: `$union V1 V2 ...`. |
| `$as` | 2 | Reinterpret cast: `$as expr TargetType`. |
| `$overload` | 1–∞ | First-class overload aggregate: `$overload expr1 expr2 ...`. |
| **Arithmetic** | | |
| `$add` | 2 | Integer addition. |
| `$sub` | 2 | Integer subtraction. |
| `$mul` | 2 | Integer multiplication. |
| `$div` | 2 | Integer division. |
| `$mod` | 2 | Integer modulo (truncated). |
| `$rem` | 2 | Integer remainder (implementation extension; alias of `$mod`). |
| `$fadd` | 2 | Float addition. |
| `$fsub` | 2 | Float subtraction. |
| `$fmul` | 2 | Float multiplication. |
| `$fdiv` | 2 | Float division. |
| **Comparison** | | |
| `$eq` | 2 | Integer equality. |
| `$neq` | 2 | Integer inequality. |
| `$lt` | 2 | Integer less-than. |
| `$gt` | 2 | Integer greater-than. |
| `$lte` | 2 | Integer less-than-or-equal. |
| `$gte` | 2 | Integer greater-than-or-equal. |
| `$req` | 2 | Reference equality (compare storage-slot identity). |
| `$rneq` | 2 | Reference inequality (compare storage-slot identity). |
| **Logic** | | |
| `$and` | 2 | Logical AND. |
| `$or` | 2 | Logical OR. |
| `$not` | 1 | Logical NOT. |
| **Bitwise** | | |
| `$band` | 2 | Bitwise AND. |
| `$bor` | 2 | Bitwise OR. |
| `$bxor` | 2 | Bitwise XOR. |
| `$bnot` | 1 | Bitwise NOT. |
| `$lshift` | 2 | Left shift. |
| `$rshift` | 2 | Right shift. |
| **Type Conversion** | | |
| `$i2f` | 1 | Convert i64 → f64. |
| `$f2i` | 1 | Convert f64 → i64 (truncate). |
| **Traits** | | |
| `$traits` | 1 | Declare a trait (set of properties). |
| `$impl` | 2–3 | Implement a trait for a type. |
| **FFI** | | |
| `$extern` | 1 | Bind to a native C symbol. |
| **Implementation Extensions** (not in type lattice / grammar) | | |
| `$inline` | 1 | Inline storage hint (not in spec grammar). |
| `$forward` | 1 | Forward-declare a function body. Allocates a function table slot at the declaration site; the real body fills it when the full `$decl` is processed. Supports mutual recursion. |
| `$idtstr` | 1 | Convert intern ID to string (implementation only). |
| `$strtid` | 1 | Convert string to intern ID (implementation only). |
