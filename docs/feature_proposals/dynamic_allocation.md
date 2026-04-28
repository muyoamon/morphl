# Feature Proposal: Dynamic Storage and Deferred Cleanup


**Status**: Implemented

---

## 1. Design Goals

This proposal introduces dynamic storage and deterministic cleanup while preserving morphl's core principles:

- No implicit ownership system
- No hidden control flow
- No implicit allocation or destruction
- All lifetime behavior is explicitly expressed in code
- Shallow copy remains purely value-based

Dynamic storage is treated as a storage-location transformation, not a type-level ownership construct.

---

## 2. `$heap` - Dynamic Storage Transformer

### Syntax

```morphl
$heap <storage-expr>
```

### Semantics

`$heap` moves the storage described by `<storage-expr>` into dynamically allocated memory.

- Storage is allocated from the heap at evaluation time.
- The result is a `$ref` to the heap-backed storage.
- No ownership type is introduced.
- No automatic destruction occurs.

### Properties

| Property | Description |
|---|---|
| Lifetime | Until explicitly freed |
| Storage Location | Heap |
| Shape Contribution | Yes (as a `$ref`) |
| Ownership | Not tracked by the language |

### Example

```morphl
$decl a $heap $mut 0;   // a : $ref $mut i64
```

---

## 3. `$free` - Explicit Deallocation

### Syntax

```morphl
$free <expr>
```

### Semantics

Releases heap storage referenced by `<expr>`.

- `<expr>` must evaluate to a `$ref` pointing to heap storage.
- If the allocation carries deferred cleanup, `$free` runs that cleanup before releasing storage.
- Behavior is undefined if:
  - the reference is not heap-allocated
  - the storage has already been freed

### Type

```morphl
$free : ()
```

### Example

```morphl
$decl a $heap $mut 0;
$free a;
```

---

## 4. `$defer` - Deferred Execution

### Syntax

```morphl
$defer <expr>
```

### Core Meaning

`$defer` means: run `<expr>` after the current block goes out of scope.

- Deferred expressions execute in reverse lexical order (LIFO).
- `$defer` contributes no storage and no structural shape.
- `$defer` has type `()`.
- `$defer` is explicit scheduled cleanup, not ownership inference or destructor syntax.

### Lifetime Model

A `$defer` declared inside a block is attached to the lifetime of that block instance.

| Context | When `$defer` executes |
|---|---|
| Ephemeral block | When evaluation leaves the block |
| Captured block (`$decl`) | When the binding goes out of scope |
| Static captured block (`$static`) | On normal program termination |
| Heap-backed captured block (`$heap`) | When `$free` releases the allocation |

This keeps the source-level meaning uniform: the deferred expression runs when the block itself goes out of scope, even if that block's lifetime was extended by capture.

### Lexical Unwind

For ordinary lexical blocks, the compiler lowers `$defer` to explicit unwind code emitted in reverse lexical order.

That unwind runs on every exit path from the block:

- fallthrough
- `$ret`
- `$break`
- `$continue`

### Captured Blocks

When a block is captured by `$decl`, `$static`, or another construct that preserves the block instance, the defer list is preserved with that block lifetime rather than running immediately after initial evaluation.

Deferred actions are runtime behavior of the block instance, but they do not become structural members and do not participate in the block's exposed type.

### Heap-Backed Cleanup

If a captured block containing `$defer` is heap-backed, cleanup runs on `$free`.

The implementation model is:

- the compiler generates a cleanup thunk for the block's deferred actions
- the heap allocation carries a reference to that thunk
- `$free` invokes the thunk exactly once before releasing storage

This is explicit cleanup attached to the block instance, not a general ownership system.

### Examples

Lexical block unwind:

```morphl
{
    $decl tmp $heap $mut 0;
    $defer $free tmp;
}; // tmp is freed here
```

Captured binding:

```morphl
{
    $decl x {
        $decl a $heap $mut 0;
        $defer $free a;
    };
}; // x goes out of scope here, then $free x.a runs
```

Heap-backed captured block:

```morphl
$decl x $heap {
    $decl a $heap $mut 0;
    $defer $free a;
};

$free x;   // runs x's deferred cleanup, then releases x
```

Static captured block:

```morphl
$decl s $static {
    $decl a $heap $mut 0;
    $defer $free a;
};

// s's deferred cleanup runs on normal program termination
```

---

## 5. Shallow Copy Semantics

### Rule

```morphl
$decl y x;
```

- Copies the current value of `x`.
- Does not replay initializer logic.
- Does not duplicate defer registrations into a second independent cleanup schedule.

### Consequences

```morphl
$decl x {
    $decl a $heap $mut 0;
    $defer $free a;
};

$decl y x;
```

- `y.a` refers to the same heap storage as `x.a`.
- `y` does not receive a second independent defer list.
- No extra cleanup is introduced by the copy itself.

Whereas:

```morphl
$decl Template {
    $decl a $heap $mut 0;
    $defer $free a;
};

$decl n $new Template;
```

- `n.a` refers to a distinct heap allocation.
- `n` receives its own deferred cleanup behavior because `$new` creates a fresh block instance.

---

## 6. Why This Fits morphl

### Why no ownership type?

- Ownership introduces move semantics, drop rules, and additional control-flow complexity.
- morphl keeps lifetime management in source code through explicit storage and explicit cleanup sites.

### Why does `$heap` return `$ref`?

- `$ref` is morphl's uniform addressing mechanism.
- Storage location remains orthogonal to access semantics.
- The type system stays minimal.

### Why `$defer` instead of destructors?

- Cleanup is still explicitly written in source.
- The compiler only schedules what the programmer explicitly declared.
- No implicit resource protocol or ownership transfer is introduced.

---

## 7. Design Properties

This model ensures:

- No implicit allocation
- No implicit destruction
- No implicit ownership transfer
- Explicit deallocation via `$free`
- Deterministic cleanup timing
- Full control of lifetime through explicit code

---

## 8. Example: Dynamic Resource Wrapper

```morphl
$decl File {
    $decl handle $heap $mut $call open_file ();
    $defer $call close_file handle;
};

{
    $decl f $new File;
    // use f
}; // f goes out of scope, then close_file runs
```

---

## 9. Future Work

- A dedicated spec section for `$heap`, `$free`, and `$defer` once the surface syntax and VM lowering are fully merged into `SPEC.md`
- Optional higher-level ownership or resource-management libraries in stdlib built on top of these primitives
