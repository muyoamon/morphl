# Feature Proposal - `$implicit` keyword

---

## Design Goal

This proposal introduces `$implicit` as a **type specifier** that marks a member of a compound type (block or group) as skippable during positional type checking.

```
$implicit <expr>
```

The expression still contributes normally to the structural type and instance layout. However, during positional compatibility checks (e.g., `$set`, function calls, `$new` initializers), implicit members may be omitted by the caller. When omitted, an implicit member retains its current value.

---

## Layout Constraint

Implicit members may only appear as a **prefix**, a **suffix**, or **both** relative to the required members. Required members must form a contiguous block within the type. The allowed shape is:

```
implicit* required+ implicit*
```

Placing an implicit member between two required members is a compile error:

```morphl
($implicit 1, 2, $implicit 3, 4)   // error: implicit member between required members
```

This constraint keeps matching unambiguous and codegen simple.

---

## Matching Algorithm

When matching a provided value of arity `N` against a target type, the provided values are treated as a **contiguous window** into the target's member sequence.

**Rules:**

1. If `N` equals the required member count: match required members positionally in order. Implicit members keep their current value.
2. If `N` is greater than the required count (but ≤ total member count): find the leftmost contiguous window of size `N` in the target type that covers all required members and passes type checking. Use that window.
3. If `N` exceeds the total member count: allowed by existing structural subtyping (extra trailing fields).
4. If no valid window exists: type error.

When multiple windows satisfy the type check (only possible in the prefix+suffix case), the **leftmost window** wins. This is deterministic and requires no warning.

---

## Use Cases

### 1. Implicit Prefix

An implicit prefix is a member that exists in the object structure but is not provided in routine operations.

```morphl
$decl g1 ($implicit 1, 2, 3);
// structural type: (implicit int, int, int)
// pos 0: implicit, pos 1,2: required

$set g1 (10, 20);           // N=2 = required count → pos 1,2; pos 0 keeps its value
$set g1 (10, 20, 30);       // N=3 = full match → pos 0,1,2
$set g1 (10, 20, 30, 40);   // allowed by existing subtyping rule
$set g1 (10.0, 20);         // error: pos 1 expects int, got float
```

### 2. Implicit Suffix (Soft Subtype)

An implicit suffix is a member that must exist in the object but is not always explicitly provided by callers.

```morphl
$decl g2 (1, 2, $implicit 3);
// structural type: (int, int, implicit int)
// pos 0,1: required; pos 2: implicit

$set g2 (10, 20);           // N=2 = required count → pos 0,1; pos 2 keeps its value
$set g2 (10, 20, 30);       // full match → pos 0,1,2
```

This creates a soft subtyping relationship: a value of type `(int, int)` can be assigned to a target of type `(int, int, implicit int)`.

### 3. Implicit Prefix and Suffix

Both can appear simultaneously. When provided arity falls between the required count and full count, leftmost window wins.

```morphl
$decl g3 ($implicit 1, 2, 3, $implicit 4);
// pos 0: implicit, pos 1,2: required, pos 3: implicit

$set g3 (10, 20);           // N=2 = required count → pos 1,2
$set g3 (10, 20, 30);       // N=3: leftmost window [0,1,2] wins → pos 0,1,2
$set g3 (10, 20, 30, 40);   // full match → pos 0,1,2,3
```

---

## Codegen

Because the layout constraint guarantees implicit members only appear at the edges, `$set` with an implicit-containing target remains a single contiguous write — just potentially offset from the struct base:

- **Implicit prefix**: write starts at `base + implicit_prefix_size_bytes`, leaving the prefix untouched.
- **Implicit suffix**: write covers required members only, leaving the suffix untouched.
- **Both**: combination of the above.

No per-field scatter writes are required.

---

## Groups and Blocks

Groups are unnamed-member compound types. A group and a block with the same member types have the same structural shape regardless of member names. `$implicit` applies identically to both:

```morphl
$decl g ($implicit 1, 2, 3);           // group with implicit prefix
$decl b { $decl a $implicit 1; $decl b 2; $decl c 3; };  // block equivalent
```

---

## Implicit as Function Argument

`$implicit` on a function parameter is ergonomic default-argument syntax. The compiler expands the call site to include the default value when the argument is omitted.

```morphl
$decl f1 $func ($decl x 0, $decl y $implicit 10) {
    $ret $add x y;
}

$call f1 (10, 20);  // 30 — explicit
$call f1 (10);      // 20 — y uses default value 10
```

The calling convention is unchanged: the compiler always emits a full-arity call with the default value substituted at the call site.

---

## Implicit as Explicit `$this` Argument

Currently, the compiler implicitly passes the parent object to methods via `$parent`. `$implicit $this` makes this explicit in the function signature, giving the programmer direct control — most importantly over mutability.

```morphl
// Before: implicit parent passing — mutability not controllable
$decl a {
    $decl foo $func () { ... }  // backend implicitly passes parent
}

// After: explicit $implicit $ref $this
$decl b {
    $decl foo $func ($implicit $ref $this) { ... };           // read-only parent
    $decl bar $func ($implicit $mut $ref $this) { ... };      // mutable parent — previously impossible
};
```

**Note on `$this` and `$parent`**: since a function only provides a pseudo-scope for its arguments (which is not exposed in the function body's block), `$this` in the argument scope and `$parent` in the function body refer to the same object. `$parent` is simply the name used from inside the body block to reach that object.

### Compile-Time Mutability Enforcement on Methods

A direct consequence of explicit `$implicit $ref $this` is that the type checker can now statically assert whether a method requires a mutable or immutable instance at the call site — something previously impossible.

```morphl
$decl Counter {
    $decl value $mut 0;

    $decl get $func ($implicit $ref $this) {
        $ret $member $parent value;
    };

    $decl increment $func ($implicit $mut $ref $this) {
        $set $member $parent value $add $member $parent value 1;
    };
};

$decl c $mut $new Counter;
$call $member c get ();        // ok — read-only $this, works on any instance
$call $member c increment ();  // ok — $mut $ref $this satisfied by $mut c

$decl c2 $new Counter;         // immutable instance
$call $member c2 get ();       // ok
$call $member c2 increment (); // compile error — $mut $ref $this required but c2 is immutable
```

This mirrors the `$mut $ref` subtyping rule already in the spec: `$mut $ref T <: $const $ref T` but not vice versa. A mutable instance satisfies a read-only `$ref $this`; an immutable instance does not satisfy `$mut $ref $this`. The type checker enforces this at every call site without any new mechanism — it is a natural consequence of mutability subtyping applied to the implicit argument.
