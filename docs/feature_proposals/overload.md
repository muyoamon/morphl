# Feature Proposal: `$overload`

---

## 1. Design Goal

`$overload` introduces a first-class value that stores multiple candidate
expressions in one declaration while allowing each use site to select exactly
one candidate during the typing pass.

The selected candidate is fixed at compile time for that use site, but the
overload object itself is not compile-time-only. It may be stored, passed, and
assigned like any other value.

This is intended to generalize the existing grammar-template overload mechanism
into an ordinary source-level construct.

> **Implementation note**: the current VM implementation supports stored
> source-level overload values, projected candidate resolution, and whole-object
> assignment. Lazy `$inline $overload` behavior and C backend support remain
> follow-up work.

---

## 2. Syntax

```morphl
$overload <expr>+
```

`$overload` is variadic and accepts any expression as a candidate.

---

## 3. Core Semantics

`$overload` is group-like in storage and evaluation:

- It stores one candidate slot per child expression, in lexical order.
- It is eager by default, like other stored aggregate expressions.
- It does not select a candidate at `$decl` site.
- Candidate selection happens independently at each usage site during the typing
  pass.

Conceptually:

```morphl
$decl x $overload 0 0.0;
```

declares one value containing both an `int` candidate and a `float` candidate.

Each use of `x` projects one slot from that stored value:

```morphl
$add x 1;      // picks candidate 0
$fadd x 1.0;   // picks candidate 1
```

Codegen lowers the selected use site to a fixed slot offset in the stored
overload object.

---

## 4. Resolution Rule

At a use site, if an operand has overload type, the typing pass resolves it in
two stages:

1. Try the overload value itself first.
2. If the overload value itself is not compatible, try candidates from first to
   last.

Selection order is therefore:

- whole overload object first
- then child candidates in lexical order
- first compatible match wins
- if nothing is compatible, the expression is a type error

Candidate selection is per use site, not per declaration.

This rule aligns whole-object operations and projected-candidate operations
under one mechanism:

```morphl
$decl x $mut $overload 0 0.0;

$set x $overload 100 100.0; // x resolves to overload type first
$set x 100;                 // x falls through to int candidate
$set x 100.0;               // x falls through to float candidate
```

---

## 5. Operator Classes

The same self-first resolution rule applies everywhere. Operator classes only
determine what compatibility is being tested.

### 5.1 Type-Closed Operators

A type-closed operator already fixes the required operand types.

Examples:

- `$add`
- `$sub`
- `$mul`
- `$div`
- `$fadd`
- `$fsub`
- `$eq` when its operand requirements are already known

For these operators, each overload operand is checked against the type required
by that operator. Since the operator does not expect an overload object, the
self-check normally fails and resolution falls through to candidates.

```morphl
$decl x $overload 0 0.0;
$decl y $overload 1 1.0;

$add x y;    // resolve both as int
$fadd x y;   // resolve both as float
```

If an operand cannot resolve to the required type, the expression is rejected.

### 5.2 Type-Variable Operators

A type-variable operator does not fully determine all operand types on its own.
Instead, one operand or the surrounding context constrains the other.

Examples:

- `$set`
- `$call`
- `$ret`
- argument passing to a known parameter type

For these operators, overload resolution is driven by the expected type induced
by the operator or by another operand. Unlike type-closed operators, these
operators may accept either:

- the overload object as a whole, or
- one projected candidate

```morphl
$decl x $mut $overload 0 0.0;

$set x $overload 100 100.0; // resolve x as overload object first
$set x 100;                 // resolve x as int candidate
$set x 1.5;                 // resolve x as float candidate
```

If no candidate matches the induced type, the expression is rejected.

---

## 6. Overload Type Identity

Although `$overload` is group-like in storage, it is not an ordinary group for
typing purposes.

An overload value has an ordered candidate list. Two overload values have the
same overload type iff:

- They have the same candidate count.
- Corresponding candidates have the same type positionally.

So these have the same overload type:

```morphl
$overload 0 0.0
$overload 1 2.0
```

and these do not:

```morphl
$overload 0.0 0
$overload 0 0.0 ""
```

---

## 7. Multiple Overload Operands

When more than one operand in the same expression is overload-typed, each
operand still follows the same self-first resolution rule.

### 7.1 Type-Closed Operators

For type-closed operators, resolve each overload operand independently against
the operator's required type.

```morphl
$decl x $overload 0 0.0;
$decl y $overload 1 1.0;

$add x y;    // both resolve as int
$fadd x y;   // both resolve as float
```

No same-overload-type requirement is imposed here because the operator already
defines the concrete operand type.

### 7.2 Type-Variable Operators

For type-variable operators, whole-object behavior is available when the
operator can accept overload objects directly. In that case, both operands first
attempt to resolve as overload objects.

```morphl
$decl a $mut $overload 0 0.0;
$decl b      $overload 1 1.0;
$decl c      $overload 1 2.0 "";

$set a b;   // valid: both resolve as overload objects
$set a c;   // error: overload type mismatch
```

If whole-object resolution fails, normal candidate resolution proceeds
left-to-right for each overload operand as required by the operator.

Example:

```morphl
$decl x $overload
    $func ($decl n 0) n
    "somestr";

$decl y $overload 10 "str";

$call x y; // x resolves to function candidate, then y resolves to int candidate
```

---

## 8. Assignment Semantics

`$set` has two forms when the LHS is overload-typed.

### 8.1 Candidate Assignment

If the RHS is not overload-typed, the compiler resolves the LHS to the first
candidate compatible with the RHS type and emits a write to that slot.

```morphl
$decl x $mut $overload 0 0.0 "";

$set x 100;      // writes to int slot
$set x 1.25;     // writes to float slot
$set x "hello";  // writes to string slot
```

### 8.2 Whole-Object Assignment

If both LHS and RHS are overload-typed, the compiler first attempts whole-object
assignment by resolving both sides as overload objects. This requires identical
overload type.

```morphl
$decl x $mut $overload 0 0.0;

$set x $overload 99 99.99;   // valid
$set x $overload "" 99 0.0;  // error: overload type mismatch
```

---

## 9. Evaluation and `$inline`

Stored overload values are eager:

- Every child expression is evaluated and materialized when the overload object
  is created.
- Side effects of non-selected candidates still occur.

Inline overload values are lazy by substitution:

- `$inline $overload ...` does not allocate storage by itself.
- No candidate is materialized until a use site selects one.
- Only the selected candidate is evaluated at that use site.

Example:

```morphl
$alias a $inline $overload
    $call some_expensive_function_return_int ()
    "Hello";

$call $member io println a; // selects string candidate only
```

In this example, the expensive function call is not emitted because the inline
overload never materializes the non-selected candidate.

---

## 10. Examples

### 10.1 Arithmetic

```morphl
$decl x $overload 0 0.0;

$add x 1;      // use int slot
$fadd x 1.1;   // use float slot
```

### 10.2 Call Resolution

```morphl
$decl f $overload
    $func ($decl x 0) x
    $func ($decl x 0.0) x
    "Hello World!";

$call f 10;      // select int function
$call f 10.0;    // select float function
$call $member io println f; // select string candidate
```

### 10.3 Mutable Overload Value

```morphl
$decl x $mut $overload
    $func ($decl x 0) x
    $func ($decl x 0.0) x
    "String here!";

$set x $func ($decl x 0) $add x 1; // set int-function slot
$set x "New String!";              // set string slot
$set x $overload
    $func ($decl x 0) $sub x 1
    $func ($decl x 0.0) $sub x 1
    "Hi!";                         // replace whole overload object

$set x $func ($decl x "") x;       // error: no compatible candidate
```

---

## 11. Summary

`$overload` is a first-class aggregate value whose storage is group-like but
whose usage is context-sensitive.

- It stores all candidates unless inlined.
- It resolves by trying the overload object itself first, then candidates.
- Type-closed and type-variable operators share the same core resolution rule.
- Whole-object behavior emerges naturally when the surrounding operator can
  accept overload type directly.
- First-match wins in lexical order.
