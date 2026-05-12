# Feature Proposal: `$template` and `$specialize`

---

## 1. Design Goal

`$template` introduces a first-class static template value: an expression object
whose body may depend on generic parameters, while still having a fixed static
template type.

`$specialize` applies concrete substitution expressions to a template value. The
substitution expressions have ordinary compile-time-known morphl types, so the
specialized result type is known exactly during typing.

The goal is to add generic-dependent expression abstraction without introducing
true dynamic typing. A template may be stored, passed, and assigned like other
values, but compatibility remains governed by static template types and
subtyping rules.

Template functions are not a separate mechanism. A function template is simply a
template whose body expression is `$func`; specialization substitutes generic
parameters through the function parameter declaration, body, and return type
using the same rules as any other template body.

This differs from source-level `$overload`: `$overload` stores concrete
candidates and projects one candidate at each use site, while `$template`
describes one dependent expression whose concrete operations are resolved by
specialization.

---

## 2. Syntax

```morphl
$template <ident-group> <expr>
$specialize <template-expr> <expr-subs-group>
```

`<ident-group>` declares one or more generic parameter identifiers. The group
shape determines how many substitution expressions `$specialize` must provide.
The template body may be any expression, including `$func`.

Examples:

```morphl
$decl get_x $template T $member T x;

$decl result $specialize get_x some_value;
```

```morphl
$decl add_x $template T $add $member T x 1;

$decl result $specialize add_x some_value;
```

```morphl
$decl f $template T $func ($decl x T) $add x 1;

$decl int_f $specialize f 0;
```

The generic identifier may also appear directly in the function body:

```morphl
$decl f $template T $func ($decl x T) $add x 1;
```

Specializing this with `0` types the function as if both occurrences of `T`
were replaced by `0`.

---

## 3. Core Semantics

`$template` is a static abstraction over an expression.

Inside the template body, each declared generic identifier denotes a
generic-dependent expression. Operations that depend on a generic expression do
not need to resolve to concrete offsets, layouts, or result types when the
template is declared.

For example:

```morphl
$template T $member T x
```

does not choose an offset for `x` at declaration time. The member access remains
dependent on the eventual substitution for `T`.

`$specialize` supplies concrete substitution expressions:

```morphl
$specialize ($template T $member T x) value
```

Typing `$specialize` behaves as if the compiler substituted `value` for `T`,
then typed the resulting expression with ordinary morphl rules:

```morphl
$member value x
```

The `$specialize` expression has exactly the type produced by that substituted
expression.

The same rule applies when the template body is a function. In:

```morphl
$template T $func ($decl x T) $add x 1
```

the generic identifier `T` appears in the function parameter declaration. A
specialization substitutes the concrete expression for `T`, then types the
resulting function normally. For example, specializing with `0` produces a
function whose parameter is typed like `0`, and whose body is checked with that
parameter type.

---

## 4. Dependent Constraints

Template declarations may contain generic-dependent expressions whose concrete
type is not known until specialization.

Unconstrained dependent expression:

```morphl
$template T $member T x
```

This means: for any valid substitution expression `S`, the specialized result is
the type of `$member S x`.

Typed contexts may constrain dependent expressions:

```morphl
$template T $add $member T x 1
```

Because `$add` requires integer operands, any valid specialization must make
`$member T x` resolve to an `int`-compatible expression.

These constraints are derived from ordinary typing rules. They are not separate
user-written trait or interface declarations.

If a substitution cannot satisfy the derived constraints, `$specialize` is a
type error.

---

## 5. Template Type Identity

A template type is determined by:

- its generic parameter group shape
- its dependent body/result pattern
- the validity constraints implied by typing the body

Template type identity is not based on one later successful specialization.

For example:

```morphl
$template T $member T x
$template T $member T y
```

are not generally the same template type, even if a particular substitution has
compatible `x` and `y` fields.

However, two syntactically different template bodies may still be compatible if
their template subtyping relation can be proven under the rule below.

---

## 6. Template Subtyping

Template subtyping is universal over the same substitution expressions.

Template `A` is a subtype of template `B` iff, for every substitution group `S`
valid for both templates:

```text
$specialize A S <: $specialize B S
```

The same substitution group must be used for both sides. This prevents
use-site-specific accidental compatibility from redefining the template type.

Example:

```morphl
$decl get_x $template T $member T x;
$decl get_y $template T $member T y;
```

`get_x` is not a subtype of `get_y` merely because some concrete type has
compatible `x` and `y` fields. The relation must hold for every same
substitution group accepted by both templates.

If the compiler cannot prove a template subtype relation, it rejects the
operation that requires the relation.

---

## 7. Specialization

`$specialize` is the only operation that turns a template value into an ordinary
expression result.

Specialization proceeds conceptually as:

1. Infer the static template type of `<template-expr>`.
2. Infer the ordinary static types of `<expr-subs-group>`.
3. Match the substitution group shape against the template parameter group.
4. Substitute the expressions into the template body.
5. Resolve generic-dependent operations under the substituted expressions.
6. Return the exact type of the substituted expression.

Example:

```morphl
$decl get_x $template T $member T x;

$decl a {
  $decl x 1;
};

$decl b {
  $decl x 1.0;
};

$decl ax $specialize get_x a; // int
$decl bx $specialize get_x b; // float
```

The same template can specialize to different concrete result types, but each
specialization result is statically known.

When specialization returns a function, the result is an ordinary function type:

```morphl
$decl f $template T $func ($decl x T) $add x 1;

$decl int_f $specialize f 0; // function from int-like x to int
```

Specialization substitutes `0` for the generic parameter `T`, so the function
parameter declaration is typed as if it were `($decl x 0)`. The function body is
then checked normally under that parameter binding.

---

## 8. Evaluation and `$inline`

Templates are first-class values. A non-inline template may be stored, passed,
and assigned without copying or monomorphizing its body at every specialization
site.

`$inline $template` permits direct substitution:

```morphl
$alias get_x $inline $template T $member T x;

$decl result $specialize get_x value;
```

The compiler may lower this as direct substitution of `value` into the template
body.

Non-inline templates use wrapper-style lowering:

```morphl
$decl get_x $template T $member T x;

$decl result $specialize get_x value;
```

The specialized expression still has the exact substituted type, but codegen
lowers the call through a wrapper or adapter around the stored template value
rather than duplicating the template body as if it were inline.

Both lowering strategies must preserve the same typing behavior.

---

## 9. Assignment and Mutability

Template values may be mutable:

```morphl
$decl get $mut $template T $member T x;

$set get $template T $member T y;
```

The assignment is valid only if the RHS template is a subtype of the declared
template type of `get`.

Mutation may change the implementation logic of a template value, but it cannot
change the static template contract of the storage location.

This mirrors ordinary assignment: the stored value may change, but the declared
type remains fixed.

---

## 10. Examples

### 10.1 Generic Member Projection

```morphl
$decl get_x $template T $member T x;

$decl point {
  $decl x 10;
  $decl y 20;
};

$decl x $specialize get_x point; // int
```

The member offset for `x` is resolved when `point` is substituted for `T`.

### 10.2 Constrained Arithmetic

```morphl
$decl inc_x $template T $add $member T x 1;

$decl valid {
  $decl x 10;
};

$decl invalid {
  $decl x "text";
};

$decl a $specialize inc_x valid;   // valid: int
$decl b $specialize inc_x invalid; // type error
```

The template itself is generic, but the use of `$add` constrains `T.x` to an
integer-compatible expression for every valid specialization.

### 10.3 Template Function

```morphl
$decl add_one $template T $func ($decl x T) $add x 1;

$decl add_one_int $specialize add_one 0;
$decl result $call add_one_int 41; // int
$decl direct_result $call ($specialize add_one 0) 41; // int
```

Template functions are not a separate feature. They are ordinary template values
whose body expression is `$func`. Generic substitutions may appear in function
parameter declarations, return expressions, nested blocks, and any other
expression position that ordinary typing can resolve after substitution.

### 10.4 Inline Template

```morphl
$alias get_x $inline $template T $member T x;

$decl result $specialize get_x value;
```

The compiler may lower this by substituting `value` directly into the template
body.

### 10.5 Stored Template

```morphl
$decl get_x $template T $member T x;

$decl result $specialize get_x value;
```

The compiler preserves `get_x` as a first-class value and lowers specialization
through a wrapper or adapter.

---

## 11. Non-Goals

This proposal does not introduce:

- true dynamic runtime types
- use-site-only duck typing as the core compatibility rule
- mandatory member offset or field type resolution at template declaration time
- user-written template requirement declarations
- a requirement that inline and non-inline lowering have the same internal code
  shape

Only the observable typing behavior must match between inline substitution and
stored-template wrapper lowering.

---

## 12. Implementation Notes

A future implementation will likely need a dedicated template type kind that can
store:

- generic parameter group shape
- template body AST
- dependent result pattern
- constraints derived from typed uses inside the body

The parser only needs to recognize `$template` and `$specialize` arities. The
typing pass is responsible for preserving generic-dependent expressions inside
template bodies and resolving them during `$specialize`, including occurrences
inside `$func` parameter declarations and function bodies.

VM support can initially follow the semantic split described above:

- `$inline $template` lowers by substitution
- stored `$template` values lower through wrapper or adapter code
