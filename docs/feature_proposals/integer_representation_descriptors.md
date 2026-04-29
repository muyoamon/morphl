# Feature Proposal: Integer Representation Descriptors

---

## 1. Design Goals

This proposal introduces expression-attached representation descriptors for
integers:

- `$size`
- `$align`
- `$signed`
- `$unsigned`

The goal is to let morphl describe non-VM-native integer layouts and ABI views
without changing morphl's core arithmetic model.

This proposal keeps the language split into:

- one abstract integer model for ordinary computation
- one representation-descriptor layer for value normalization and storage layout

In particular:

- morphl `int` remains the default integer type
- integer arithmetic remains VM-native 64-bit arithmetic
- representation descriptors do not introduce new primitive types
- integer size is not baked into the type system

This is intended to support stable foreign-layout APIs such as C-style scalar
fields and parameters while keeping the core language small.

---

## 2. Syntax

```morphl
$size <byte-count> <expr>
$align <byte-count> <expr>
$signed <expr>
$unsigned <expr>
```

All four are ordinary expression-attached descriptors, consistent with existing
morphl descriptor style.

Examples:

```morphl
$decl c_char $size 1 $signed 0;
$decl c_uchar $size 1 $unsigned 0;
$decl c_int $align 4 $size 4 $signed 0;
```

---

## 3. Scope

This proposal supports integer-typed expressions only.

For now:

- `$signed` and `$unsigned` are valid only on integer-typed expressions
- `$size` is valid only on integer-typed expressions
- `$align` may wrap any expression

Non-integer behavior is intentionally left unspecified until the ABI model is
more stable.

Examples that are valid under this proposal:

```morphl
$size 1 1000
$unsigned $size 2 -1
$align 4 $size 4 0
$align 16 ()
$align 8 "abc"
```

Examples that are type errors under this proposal:

```morphl
$signed "hello"
$unsigned ()
$size 8 "abc"
```

---

## 4. Core Model

These descriptors do not create new integer types. `$size`, `$signed`, and
`$unsigned` describe how an integer expression is normalized or stored.

`$align` is broader: it is a storage/layout descriptor that may wrap any
expression, but it does not change pure runtime value evaluation.

Conceptually, each integer expression may carry two layers:

- abstract value kind: morphl `int`
- optional representation metadata:
  - byte width
  - signedness
  - alignment

The abstract computation model remains unchanged:

- all ordinary integer operators compute in VM-native 64-bit integer space

Descriptors affect:

- integer value normalization when the descriptor-wrapped expression is
  evaluated
- storage layout where alignment and width matter
- load/store conversion for sized integer storage

Descriptors do not by themselves create a distinct nominal or structural type.

---

## 5. `$size`

### Meaning

`$size N expr` constrains the represented width of an integer expression to `N`
bytes.

This is a representation-width descriptor, not a new type constructor.

### Value Semantics

When evaluated as a value:

1. evaluate `expr` as a normal morphl integer
2. truncate the result to the low `N` bytes
3. interpret the truncated bits using the active signedness
4. promote back to VM-native integer width

So:

```morphl
$size 1 1000
```

does not remain `1000`. It normalizes through an 8-bit representation first.

### Examples

```morphl
$size 1 $unsigned 1000   // 232
$size 1 $signed 255      // -1
$size 2 $unsigned -1     // 65535
$size 2 $signed 65535    // -1
```

### Width Domain

For now, valid widths should be restricted to the widths the VM/backend
explicitly supports. A conservative initial set is:

- `1`
- `2`
- `4`
- `8`

Other byte counts should be rejected until the VM has explicit support for
them.

---

## 6. `$signed` and `$unsigned`

### Meaning

`$signed expr` and `$unsigned expr` declare how a sized integer value should be
interpreted when promoted to VM-native integer width.

They do not change the abstract type of the expression. They change the
interpretation of truncated bits.

### Rules

- `$signed` means sign-extend when promoting from a narrower representation
- `$unsigned` means zero-extend when promoting from a narrower representation
- without an explicit signedness descriptor, integer expressions use morphl's
  default integer signedness

This proposal assumes the default morphl integer model remains signed.

### Integer-Only Restriction

These descriptors are valid only for integer-typed expressions.

Examples:

```morphl
$signed $size 1 255      // -1
$unsigned $size 1 255    // 255
```

---

## 7. Descriptor Ordering

Descriptors attach to expressions and may be nested in source.

The effective representation should be read from the descriptor stack around the
expression:

- width comes from the nearest applicable `$size`
- signedness comes from the nearest applicable `$signed` or `$unsigned`
- alignment comes from the nearest applicable `$align`

Examples:

```morphl
$signed $size 1 255
$size 1 $signed 255
```

Both describe an 8-bit signed interpretation of `255`.

The exact AST nesting is surface syntax; semantically these descriptors form one
representation view over the underlying integer expression.

---

## 8. Arithmetic Semantics

Integer arithmetic remains VM-native 64-bit arithmetic.

However, descriptor-wrapped expressions are normalized before participating in
the enclosing operator.

Example:

```morphl
$add ($size 1 1000) 2
```

is evaluated as:

1. evaluate `1000`
2. truncate to 1 byte
3. promote back to morphl `int`
4. add `2`

So the result is equivalent to:

```morphl
$add 232 2
```

This keeps ordinary arithmetic width fixed while still making descriptor
wrappers semantically meaningful in expression position.

### Unsigned-Sensitive Operators

Some operators need explicit unsigned behavior even though the VM-native value
width remains 64-bit.

At minimum, unsigned forms are needed for:

- division
- remainder
- ordered comparison
- right shift

Unsigned multiplication is not required if multiplication is defined as ordinary
low-64-bit integer multiplication.

The exact surface syntax for unsigned-sensitive operators is left to follow-up
work. This proposal only establishes the need.

---

## 9. `$align`

### Meaning

`$align N expr` attaches alignment metadata to an expression.

Unlike `$size`, `$align` does not change pure integer value evaluation.

Unlike `$signed`, `$unsigned`, and `$size`, `$align` is not restricted to
integer expressions.

### Effect

`$align` matters only in storage- and layout-sensitive contexts such as:

- `$decl`
- block field layout
- static/global storage
- heap allocation layout
- extern/native ABI layout
- typed reference access

Example:

```morphl
$decl x $align 4 $size 4 0;
```

Here:

- `$size 4` controls width
- `$align 4` controls placement/alignment requirements

### Non-Storage Contexts

If `$align` appears in a pure value context:

```morphl
$add ($align 4 1) 2
```

the alignment metadata has no effect on the arithmetic result.

It is still legal syntax so that morphl descriptor usage remains uniform.

### Non-Integer Expressions

`$align` may legally wrap non-integer expressions:

```morphl
$align 16 ()
$align 8 "hello"
$align 4 {
  $decl x 0;
}
```

This proposal does not require every such use to have an immediate practical
effect. It only establishes that `$align` is a general storage/layout
descriptor rather than an integer-only value-normalization descriptor.

---

## 10. Storage and Load/Store Semantics

Representation descriptors affect memory operations as follows.

### Loads

Loading a sized integer value:

1. read the stored width
2. promote to VM-native width
3. sign-extend or zero-extend according to signedness

### Stores

Storing into a sized integer location:

1. evaluate the source expression to a VM-native integer
2. truncate to the destination width
3. write only that many bytes

The destination storage representation controls the final stored layout.

### Implication

This proposal therefore requires byte-width-aware integer load/store behavior in
the VM and backend for supported widths.

---

## 11. Type-System Position

These descriptors should not become part of morphl's abstract integer type
identity.

So all of these still fundamentally inhabit the same abstract integer kind:

```morphl
0
$size 1 0
$size 4 0
$unsigned $size 2 0
```

The differences are representation metadata, not distinct integer types.

This keeps the type system simple while still permitting ABI-specific layout and
conversion behavior.

---

## 12. FFI Motivation

This model is intended to support stable foreign integer layouts without forcing
morphl to adopt the host language's primitive type system.

Examples:

```morphl
$decl c_char $size 1 $signed 0;
$decl c_uchar $size 1 $unsigned 0;
$decl c_short $size 2 $signed 0;
$decl c_uint $size 4 $unsigned 0;
```

morphl code still computes using VM-native integers, while descriptors define
how values are normalized or stored at ABI boundaries.

---

## 13. Examples

### 13.1 Narrowing in Expression Position

```morphl
$decl x $add ($size 1 $unsigned 1000) 2;
```

`1000` is first reduced through an 8-bit unsigned representation, then used in
the add.

### 13.2 Signed Reinterpretation

```morphl
$decl x $signed $size 1 255;
```

`x` becomes `-1` as a morphl integer value.

### 13.3 Narrow Stored Field

```morphl
$decl Point {
  $decl x $align 2 $size 2 $signed 0;
  $decl y $align 2 $size 2 $signed 0;
};
```

This describes 2-byte signed integer fields while keeping morphl arithmetic
native-width when values are loaded into expressions.

---

## 14. Non-Goals

This proposal does not yet define:

- non-integer `$size`
- float representation descriptors
- opaque raw-byte storage values
- full cross-platform ABI compatibility rules
- surface syntax for unsigned-sensitive arithmetic operators

Those are follow-up topics.

---

## 15. Summary

This proposal gives morphl a consistent descriptor-based model for non-default
integer representation:

- descriptors remain expression-attached
- morphl keeps one VM-native integer arithmetic model
- `$size` and signedness normalize integer expressions
- `$align` affects storage/layout only
- integer size does not become part of type identity

That provides a practical foundation for FFI-facing integer APIs while keeping
the core language model simple.
