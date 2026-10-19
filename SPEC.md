# morphl — Language Specification (Draft 4)

*Status: core semantics, memory model, FFI, and syntax closed. Remaining items are listed in §11.*

---

## 1. Philosophy

- **Everything is an expression.** There are no statements. Blocks, declarations, functions, matches, and templates all evaluate to values.
- **Static types, inferred from expressions.** There is no syntax for writing a type. A type is always the type *of some expression*. Where a type is needed as a bound or pattern, an example expression is written and only its type is used.
- **Structural, never nominal.** Two values are compatible when their shapes are compatible. No type is declared, and conformance is never registered: a type conforms by having the props, or by an `$impl` written where it is used. Subtyping is the only implicit coercion.
- **Fixed at declaration.** A name's type is fixed by its initializer and never changes because of later use.
- **One mechanism per concept.** Namespace, scope, record, and module are the same thing (a block). Recursion, forward reference, and recursive data use one placeholder rule. Traits are blocks of props.
- **Explicit over implicit.** Application, mutability, specialization, and conformance are all written down. Where the compiler must choose (overloads, match arms), it chooses by source order, first fit, and lints unreachable cases.
- **No configuration language.** Build and test are ordinary programs run one stage earlier.

---

## 2. Syntax

The language is prefix notation with **fixed arity** for every keyword. There is no precedence, no infix operators, and no required separator.

### 2.1 Lexical elements

| Element | Form |
|---|---|
| Integer literal | `0`, `42`, `-7` |
| Float literal | `0.0`, `3.14` |
| String literal | `"hi"`; escapes `\n \t \\ \"` and `\u{…}`; validated as UTF-8 at compile time |
| Boolean tags | `true`, `false` |
| Name | identifier |
| Projection | postfix `.name` or `.1`, `.2` (group index) |
| Group | `( e, e, … )` — comma separated |
| Block | `{ e e … }` — no separator required |
| Optional separator | `;` — permitted anywhere between expressions, no meaning |
| Keyword | `$name` — compiler forms only (§2.2) |
| Comment | `//` to end of line; `/* … */` block, non-nesting; whitespace to the parser |

**Keywords are `$`-prefixed.** Every compiler form begins with `$` (`$decl`, `$call`, …); identifiers may not start with `$`. Bare names — including every intrinsic such as `add` or `print` — are ordinary values and may be shadowed. `true` and `false` are literals, not keywords. A reader can tell form from value at a glance.

Newlines are whitespace. The language does not dictate formatting.

### 2.2 Keyword arities

| Form | Arity | Operands |
|---|---|---|
| `$decl name e` | 2 | name, expression |
| `$prop name e` | 2 | name, compile-time expression |
| `$fwd name` | 1 | name |
| `$new e` | 1 | expression |
| `$alloc e` | 1 | expression |
| `$mut e` / `$const e` | 1 | reference-typed expression |
| `$set target e` | 2 | `&mut` target, expression |
| `$func params body` | 2 | group of decls, expression |
| `$call f args` | 2 | function, group |
| `$match e arms` | 2 | scrutinee, group of `$case` forms |
| `$case pat body` | 2 | type-only pattern, expression; only inside `$match` |
| `$if c a b` | 3 | sugar for `$match c ($case true a, $case false b)` |
| `$do e1 e2` | 2 | expression, expression (tail position) |
| `$overload cands` | 1 | group |
| `$union members` | 1 | group |
| `$template T body` | 2 | name or group of names, expression |
| `$specialize t args` | 2 | template, expression or group |
| `$impl x trait override` | 3 | value, trait, block of props |
| `$traitsof e` | 1 | block |
| `$import "name"` | 1 | string literal |
| `$try e pat` | 2 | expression, type-only pattern |
| `$extern "symbol" sig` | 2 | string literal, type-only signature |

Because every form has fixed arity and groups/blocks are delimited, parsing needs no separators, no newline sensitivity, and no formatter.

### 2.3 Groups

- A group is a tuple. `(a, b)` has two elements, indexed `.1`, `.2`.
- **A one-element group is the element.** `(e)` is just `e`. There is no one-tuple.
- **The empty group `()` and the empty block `{}` are the same value** (unit).

### 2.4 Application

`$call f args`. `args` is a group; by 2.3, `$call f (x)` and `$call f x` are equivalent single-argument calls. Application is never implicit.

---

## 3. Values and Types

### 3.1 Base types

`Int` (64-bit; **overflow panics**; wrapping and saturating forms are explicit intrinsics), `Float` (64-bit IEEE 754; **never panics** — division by zero and invalid operations give infinities and NaN, §8), `Str` (immutable, pointer + length, **always valid UTF-8**). There is no character type: a character is a one-code-point substring.

Literals have their base type: `0 : Int`, `"hi" : Str`. There are no singleton literal types.

### 3.2 Booleans

`true` and `false` are two distinct **nullary tag types**. `Bool` is the union `true | false`. They are the only literals that are types; conceptually they are the language's one built-in sum type, and `$if` is `$match` over them.

### 3.3 Blocks

A block `{ … }` is a scope. Its **value** is the collection of its `$decl` slots; its **type** is the ordered list of `(name, type)` for those slots plus its props.

- `$decl` fields are **ordered** and form the block's **layout**, in source order.
- `$prop` fields are in the namespace and type but **not** in the layout (§4.10).
- Non-`$decl` expressions in a block run for effect and are discarded.

A block never yields "the last expression." To compute and return a value: `{ … $decl r e }.r`.

Blocks are also records, modules and namespaces. A source file is a block.

### 3.4 Functions

`$func params body`. `params` is a group of `$decl`s; each default fixes the parameter's type. Parameters are ordinary declarations (immutable bindings). Defaults are evaluated at call time when the argument is omitted.

A function's type is `params -> result`, where `result` is the type of `body`.

### 3.5 References

`&T`, `&mut T`, `&const T` — storage holding a `T`. See §5.3.

Storage also has a **kind**, fixed where it is created and carried in its type:

- **frame** storage (`$new`, §4.2) is a *place* in the activation that made it, and is
  released when that activation ends. It is free — no allocator, no bookkeeping — and
  it may not outlive the activation that made it (§5.3a).
- **allocated** storage (`$alloc`, §4.2a) comes from an `allocator` and lives
  until that allocator releases it. A reference to it is a pointer value, which may
  be stored and may outlive anything.

The kind is written `&T` for frame and `&^T` for allocated *in diagnostics only*
— there is still no syntax for writing a type (§1). Which kind an expression has
follows from which form created the storage.

### 3.6 Unions, intersections, bottom

Types form a lattice with `|` (union) and `&` (intersection), and `⊥` (bottom, the type of `panic`). Unions arise from `$if`/`$match`, recursion, and the `$union` form (§4.8a); there is still no type syntax — `$union` takes example expressions.

### 3.7 Overloads, templates and trait objects

An `$overload` is a group whose static type records "resolve by index" (§4.8). A `$template` is a compile-time abstraction (§4.9). Both are ordinary values that can be bound with `$decl`. A **trait object** (§6) is a reference to a value together with the implementation its calls dispatch to; its type is a **trait**.

---

## 4. Forms

### 4.1 `$decl name e`

Binds `name` to the value of `e`. The binding is immutable and its type is exactly the type of `e`. Evaluates to the value.

Inside a block, `$decl` also adds an ordered slot to the block.

Scope: `name` is visible from this point onward in the enclosing block. Additionally, when `e` is a `$func`, `$template`, or block, `name` is in scope **inside `e`** (self-reference), subject to the rule that it may only be *read* from inside a `$func` body — i.e., not while `e` itself is still being evaluated.

In *type-only positions* (§5.7) a name may be referenced while its own declaration is still in progress.

**A name is bound once in a block.** No two items of one block may bind the same name, whether by `$decl`, `$fwd` or `$prop` — with the single exception §4.11 already states, that a `$fwd` and the one `$decl` completing it are one slot. §3.4 makes a parameter list a group of `$decl`s, so the same holds there: two parameters of one name are two frame slots (§7.2) of which only the second is reachable. This is not a restriction on shadowing — a nested block, a parameter, or a later file may freely rebind a name from an *enclosing* scope. It is that two slots of one name are two *fields*, and §7.2 makes the slots the layout while §4.6 finds a field by searching it in order — so the name would mean the last binding read from inside the block and the first read through a projection. One name, two values.

`$decl x 0` is permitted but unnecessary; a value that will vary should be `$new`, a constant should be `$prop`.

### 4.2 `$new e`

Allocates storage holding the value of `e` and evaluates to a reference `&T`, where `T` is the type of `e`. If `e` is itself a reference, it is dereferenced first (so `$new r` is a copy, not an alias).

`$new` makes **frame** storage: a *place* in the activation that made it — the call of
the enclosing function, or, at a file's top level, the program — released when that
activation ends, at no cost and with no allocator (§7.6). In exchange it may not
outlive the activation; §5.3a's three rules are what make the release safe.

As a parameter's default (§3.4), `$new e` makes the parameter a place — pass by
reference: the caller lends storage it owns, and the function borrows it.

`$new` and `$alloc` (§4.2a) are the **only** ways storage comes into existence. A
`$decl` never creates a cell.

### 4.2a `$alloc e`

Allocates storage holding the value of `e` from the `allocator` in lexical scope at the
point `$alloc` is written (§7.6) and evaluates to a reference `&^T` — a pointer value,
which may be stored and copied like any other. As with `$new`, a reference operand is
dereferenced first, and the value may not carry a place (§5.3a).

Allocated storage may outlive any scope, so nothing restricts where its
references go. What releases it is the allocator, when the author says so:
`$alloc` is **unsafe by declaration**, the same status §4.16 gives `$extern`. A
reference used after its allocator released it is the author's error, and the
type system does not pretend otherwise.

### 4.3 `$mut e` / `$const e`

`e` must have a reference type. `$mut e : &mut T`, `$const e : &const T`. `$mut` applied to a `&const` is an error. Applying either to a non-reference is an error.

### 4.4 `$set target e`

`target : &mut T` (or `&T`, see §5.3) and `e : T'` with `T' <: T` (dereferencing `e` if it is a reference). Writes and evaluates to the written value.

`$set` writes *through* storage. It never rebinds a name and never replaces a block field: `$set x.a 1` works if field `a` holds storage (`$decl a $new 0`), and is an error if `a` is a value field (`$decl a 0`).

### 4.5 Blocks and groups

See §3.3 and §2.3. Blocks are values; copying a block copies its fields, and fields holding references still alias. Aliasing occurs exactly where `$new` was written and nowhere else.

### 4.6 Projection `e.name`, `e.1`

Field access on blocks, index on groups. If `e` is a reference, projection reaches through it (§5.4). Projecting a `$decl` field yields its value or reference as declared; projecting a `$prop` yields the compile-time constant.

### 4.7 `$match e arms`

`arms` is a group of `$case pat body` forms. A pattern is **any expression, never evaluated**; only its static type `P` is used. An arm applies when the runtime type of `e` is a subtype of `P`. Arms are tried in order, first fit.

- Inside an arm, `e` (by its name) is narrowed to `type(e) & P`. If `e` is a `&mut` reference, the narrowing applies to the pointee and stays exact (`&mut` is invariant), so writes through it are allowed.
- `$match` binds nothing. Fields are reached through the narrowed scrutinee.
- **Exhaustiveness is required.** Uncovered members of `e`'s type are an error. A catch-all is `$match x ($case x …)`: the pattern's type is the scrutinee's full type.
- An arm whose type is covered by an earlier arm is unreachable → lint.
- Block patterns compare props as part of the type: `{$prop kind "circle"}` matches only blocks whose `kind` prop has that value.
- A literal pattern is its base type: `$match x ($case 0 …)` means `Int`. Dispatch on runtime values is done with `$if` and `eq`, not `$match`.
- **A trait object is not inspected.** A scrutinee of trait-object type (§6) has an erased referent type, so a pattern on it is decided statically: an arm whose pattern's type is a supertype of the trait object's type always matches, and any other arm can never match and is an error. To distinguish kinds of value, put the trait object in a union and match on the union (§7.5's discriminator belongs to the union), or ask the object through a member.

`$match` is the **only** construct that inspects runtime type information.

### 4.8 `$overload cands`

`cands` is a group. At runtime an overload *is* that group. Its static type additionally marks it as an overload set, ordered as written.

**Resolution** happens at any use site that expects a single type, and lowers to projection `x.i`:

- In `$call f args`: if `f` is an overload, pick the **first** candidate whose parameter types accept `args`. If an argument is an overload, pick the first candidate accepted by the parameter. Resolve left to right, no backtracking.
- If a candidate is itself an overload, it fits if any of its candidates fit (recursive; no flattening rule).
- `$decl y x` where `x` is an overload keeps `y` an overload (nothing constrains it yet).
- Passing an overload as an argument is fine if the parameter's default is an overload with matching candidate types; otherwise it resolves.
- `$set x ($overload …)` requires identical candidate types in identical order.
- `$set x.i e` replaces a candidate; the new value must match that slot's type.

An overload is a *type-level switch*: write specific candidates first, general ones later. A candidate whose parameter types are a subtype of an earlier candidate's is unreachable → lint.

### 4.8a `$union members`

`members` is a group `(e₁, …, eₙ)`. The expression **evaluates to `e₁`** and has static type `type(e₁) | … | type(eₙ)`. Elements after the first are never evaluated; only their types are used, exactly as with `$match` patterns.

`$union` is the mirror of `$overload`: both take one group, but `$overload` keeps every candidate and selects by index, while `$union` keeps the first value and joins the types. It is the way to give a name, parameter, or bound a union type without a runtime branch:

```
$decl s $union (circle, square)        // s : circle | square, value circle
$decl area $func ($decl s $union (circle, square)) $match s ( … )
```

A member whose type is a subtype of another member's is redundant → lint.

Members after the first are **type-only positions** (§5.7): they may reference names still being defined, which is how recursive data types are named:

```
$prop node $union (nil, { $prop tag "cons"  $decl head T  $decl tail node })
// value nil, type μR. nil | {tag "cons", head: T, tail: R}
```

### 4.8b `$do e1 e2`

Evaluates `e1`, discards its value, then evaluates `e2`. Has the type of `e2`. **`e2` is in tail position** when the `$do` is. Nest for longer sequences: `$do a ($do b c)`.

`$do` is a real form, not sugar: no combination of blocks and projection puts a call after an effect in tail position, and loops need exactly that.

### 4.9 `$template T body` and `$specialize t args`

A template is a compile-time abstraction. `T` (or each name in a group) denotes a *generic-dependent expression* inside `body`. `body` is **not** type-checked at declaration.

`$specialize t args`:

1. Evaluates each argument **once** and binds it to the corresponding generic name, as if `$decl T arg` were prepended to `body` (substitution by reference, never textual — an argument's side effects happen once per evaluation of the `$specialize`).
2. Types the resulting expression with ordinary rules.
3. Has exactly the type of that expression.

**Typing is memoized per argument type, and per argument value for each compile-time generic; values are not otherwise memoized.** Two specializations whose arguments have the same types, and the same values for the compile-time generics, have the same type and share the same code. A `$specialize` expression is evaluated where it stands, like a block literal written there: each evaluation evaluates the arguments once, binds them, and evaluates the body's `$decl`s in source order (§4.10), producing a new value.

- **An instance is an evaluation.** Two `$specialize t Int` written in two places are two instances. One written inside a `$func` is a new instance each time that `$func` runs. One bound by a top-level `$decl` is evaluated once, in §4.10's order, and every use of that name sees the same instance.
- **Storage belongs to the instance.** A `$new` in the body is frame storage of the scope the `$specialize` is evaluated in, and §5.3a applies to it exactly as to a block literal there. A specialization that must outlive that scope is built with `$alloc`. A `$decl $func` member's code is shared, and its environment is its own instance's (§7.3).
- **Props are shared.** A prop is compile-time and part of the type (§4.10), so every instance with the same memo key has the same props. A prop-only body therefore has exactly one value per memo key, and how many times it is evaluated cannot be observed.

**Compile-time generics.** A prop's value is part of the type (§4.10). So a generic whose value reaches a prop after specialization is a *compile-time generic*. A generic reaches a prop when it is read in an evaluated position of a `$prop` initializer anywhere in the body, at any depth, including a block literal inside a `$decl` or a `$func`. It also reaches one when it is passed as the argument for another template's compile-time generic. Its argument must be a constant expression (§4.10), and its value joins the argument types in the memo key. Given `$prop size T`, `$specialize t 5` and `$specialize t 6` are two types; without it they are one. Any other generic may be bound to any value, because only its type reaches the specialization's type. Application (`$call t args`) never infers a compile-time generic; write the `$specialize`.

**Bounds.** A generic name may carry an example: `$template (T bound) body`. The bound is a type-only position (§5.7), so it may mention `T` itself — `$template (K ($specialize ordered K))` is the F-bounded form. At specialization, `type(arg) <: type(bound)` is checked first and reported as such. A trait as a bound, `$template (T ($traitsof shape_proto))`, is satisfied by conformance (§6), and needs no F-bound: a trait's `Self` is the bounded type. The body is still typed *after* substitution; the bound is a precondition, not a proof that all conforming arguments typecheck.

**Application infers `T`.** If a template's body is a `$func`, then `$call t args` means `$call ($specialize t inferred) args`. Inference matches the **shape of each parameter default one level deep**:

- default is exactly `T` → `T` is the argument's type;
- default is a `$func` literal whose parameter defaults or body are exactly `T` → `T` is the corresponding parameter or result type of the argument's function type.

Nothing deeper is inferred (no unification through arbitrary expressions); use `$specialize` explicitly. If `T` is inferred from several places, the first in parameter order wins and the rest are checked against it. A recursive call inside the template's own body uses the same rule, so `$call fold (xs.tail, acc2, f)` re-specializes on `acc2`'s type without writing `$specialize`.

**Self-specialization** (`$decl list $template T { … $specialize list T … }`) ties the recursion knot via memoization on the memo key (§5.5). A chain of *distinct* memo keys is unbounded; there is a fixed instantiation depth limit and exceeding it is an error.

**Self-specialization and evaluation.** The memoization that ties a self-specializing template's knot (§5.5) is a typing matter. Evaluating a body whose `$decl` initializer specializes the same template evaluates that instance in turn, without bound. Like any unconditional recursion, put it inside a `$func`. The instantiation depth limit bounds typing; it does not bound evaluation.

Specializing with an overload argument is an error; resolve first.

### 4.10 `$prop name e`

Declares a **compile-time constant** member of the enclosing block. `e` must be a *constant expression*.

**Constant expressions.** An expression is constant when, with every `$specialize` in it replaced by its specialized body (§4.9: the template's body with each generic bound to its argument), it is one of:

- a literal, or `true`/`false`;
- a `$func` or `$template` literal, whose body is not evaluated here;
- a block made only of props, each initializer a constant expression;
- `$union` or `$overload` whose *evaluated* operands are constant expressions; type-only positions (§5.7) are exempt;
- `$impl` whose base and override are constant expressions (its trait is type-only, §4.12);
- a name bound to a prop, or to a generic whose argument is a constant expression;
- a projection of a constant expression.

Never `$new`, never `$call`, never a block with a `$decl`, and never `$traitsof`, which makes a reference (§6). Each argument of a `$specialize` inside a constant expression is evaluated (§4.9, step 1), so it must be a name or a constant expression. Reading a name has no effect, and if the name's value survives specialization into a prop, the rule above applies to it there.

So `$specialize P.list proto_ty` is constant whatever `proto_ty` is bound to, because `list`'s body never reads its generic's value. `$specialize t 5` is constant when `t`'s body is, with `5` in place of its generic.

**Props are visible throughout their block**, regardless of order, and are typed together as one system (§5.5). Props have no layout, so the no-hoisting rule (§4.11) does not apply to them.

- A prop is in the block's namespace and **type**, not its layout. It costs no slot.
- **A prop's value is part of the enclosing block's type.** `{$prop kind "circle"}` and `{$prop kind "square"}` are different types. This is the only place a value appears in a type, and it is how tags work.
- A prop initializer may reference other props and enclosing **compile-time** bindings — a prop of an enclosing block, or a compile-time generic (§4.9) — but not ordered siblings (there is no instance to read them from) and **not an enclosing runtime binding** such as a parameter or a `$decl`. The restriction is forced by the rule above it: a prop's value is part of its block's type and §5.1 matches props by value equality, so a prop reading a parameter would give its block a different type per call, which is not a type. (A `$specialize` argument is the one place a runtime name may stand, because its value cannot survive into a prop unless its generic is compile-time, and then the argument must be constant.)
- **The receiver.** Inside a `$func` that is a prop's value, the name of the `$decl` whose initializer is the prop's block — directly, or through `$new`, `$alloc`, `$mut`, `$const` or `$impl` (§4.12) — denotes the **receiver**: the value the member was reached through. `$call rect.area ()` passes `rect`; a call through a trait object passes its referent (§6). The receiver is a reference with the qualifier of what the block was declared as — read-only for a value, mutable for `$mut` storage — and a member that writes through its receiver needs a mutable one, which is part of the member's type. A block that no `$decl` binds, such as an anonymous literal or a template's body, has no receiver. In a type-only position (§5.7) the declaring name is the block's complete type, so a member takes another value of its own type as `$prop same_w $func ($decl other rect) …`.
- **A member taken as a value**, `$decl f rect.area`, is a closure over its receiver (§7.3), frame-bound when the receiver is (§5.3a).
- Access is uniform: `p.len` and `point.len` both work.

### 4.11 `$fwd name`

Reserves an **ordered slot** at this position in the block with a placeholder type `R_name`. Exactly one later `$decl name e` in the same block completes it: `e` is typed with `name : R_name`, the knot is tied (§5.5), and the slot takes the resulting type.

- References to `name` before its completing `$decl` are allowed only inside a `$func` or `$template` body.
- A `$fwd` not completed by the end of its block is an error.
- Layout position is the `$fwd`, not the `$decl`.
- `$fwd` promises a slot; it is never used in traits (§6).

Future extension: an optional type operand must be written as a group, `$fwd (name, example)`, to preserve fixed arity.

There is **no hoisting**. Initialization order is source order. Mutual recursion uses `$fwd`.

### 4.12 `$impl x trait override`

Implements `trait` for `x`'s type. The result is **`x`'s value, at `x`'s type with `override`'s props added** — a concrete type whose base is `x`'s. Props have no layout (§4.10), so the value is `x`'s unchanged: its fields, if it has any, are untouched, and only the type grows. `override` is a block of props supplying **every** member the trait describes and nothing else. There are no defaults, so every implementation is written for the type it implements. Each member's type must be a subtype of the trait's member type with the result's type for `Self`. `trait` is a type-only position (§5.7): only its type is used.

The result conforms to the trait by itself (§6), so it becomes a trait object the ordinary way, by coercion. Its receiver (§4.10) is the name of the `$decl` over the `$impl`, because that `$decl`'s value is the block the props belong to: `$decl n_s $impl n ($traitsof shape_proto) { $prop area $func () $call add (n_s, 0) }`. An `$impl` that no `$decl` binds has no nameable receiver; the return idiom names one. `x`'s own members keep their own receiver. A prop `x` already has is reused by naming it, `{ $prop area x.area }`, and an `override` prop whose name `x`'s type already binds is a name bound twice, which is an error (§4.1).

`x` may be of any type, including one with no props. There is no registration and no coherence problem: an implementation is chosen where it is written, and it is part of the type of the value it was written for.

### 4.13 `$traitsof e`

Makes a trait object (§6) referring to `e`, dispatching to `e`'s own props. Its type is the **trait** of `e`: the name and type of each of `e`'s props — its receiver qualifier included, the receiver itself not counted (§4.10) — with every occurrence of `e`'s type in those types abstracted as `Self`. Substitution is structural: any parameter or result whose type equals `e`'s type becomes `Self`. A trait records **signatures only**: no fields, no values, no bodies. `e` is an example of the shape and lends the trait nothing else. When `e` is a name or a reference the object refers to it; otherwise `e`'s value is placed in fresh frame storage, exactly as `$new e` would, and the object refers to that — and is frame-bound (§5.3a), as the storage is. This is explicit, so it is not §5.4's implicit conversion; a *coercion* to a trait object still needs a referable argument (§6).

### 4.14 `$import "name"`

Loads a source file as a block and evaluates to it; the type is that block's type. The operand is a string literal, resolved at compile time.

- **Loaded once.** All imports of the same resolved file yield the same block; file-level storage is shared. Top-level effects run once, at first import, depth-first from the entry file in source order of `$import`s.
- **Cycles are an error.** Mutually dependent modules: make one a `$template` over the other and let the build tie them.
- **Names are logical.** The build program supplies the resolver (search roots and an explicit name→file map), so the same `$import "net"` resolves to different files on different targets. Environment selection is an override of an edge in the build, never a change in the module.
- **Visibility.** A file sees the root block plus what it imports, nothing else.
- `$import` is a runtime value (the file may allocate), so bind it with `$decl`, not `$prop`.

### 4.15 `$try e pat`

`pat` is a type-only position (§5.7). Evaluates `e`. If its runtime type is a subtype of `pat`, **returns `e` from the nearest enclosing `$func`**; otherwise the expression's value is `e`, narrowed to `type(e) & ¬pat`.

- **Scope.** The target is always the nearest enclosing `$func`. Blocks, `$do`, `$if`/`$match` arms, and groups are transparent, as for tail positions — so `$func (…) { $decl a $try x err … $decl r … }.r` returns `x` from the function, skipping the block and the projection. A closure is a `$func`: `$try` inside a callback exits the callback.
- **Typing.** The enclosing function's inferred return type gains `type(e) & pat` as union members. Nothing else changes. Error sets are therefore inferred: a function that tries two fallible calls returns `ok T | err E₁ | err E₂`, and callers must `$match` exhaustively.
- **Outside a `$func`** (file top level, prop initializer) it is a compile error. A module that cannot initialize panics.
- `$try` is the language's only non-local exit, and only conditional. There is no `return`.

The root block declares `$prop err {$prop tag "err"}` and `$prop none {$prop tag "none"}` so the common forms read `$try x err` and `$try x none`. Any user-defined union shape works as `pat`.

**`panic` is not an error value.** It aborts; there is no catch and no unwinding. Expected failures are values; bugs panic. A panic handler is a runtime/build concern.

### 4.16 `$extern "symbol" sig`

Binds a C function. `symbol` is a string literal; `sig` is a type-only position (§5.7) whose type — an example `$func` — is the C signature. Evaluates to a callable value. Which symbols a target may see, and what is linked, is decided by the build program.

**ABI mapping.** A block is a C struct in `$decl` order (props cost nothing; they are not present at runtime). Groups likewise. `&T` and `&mut T` are thin pointers (`T*`); `&const T` may be fat, so only exact-type references cross — coerce before the call. `Int` → `int64_t`, `Float` → `double`. `Str` is pointer + length; a library `cstr` adapter produces NUL-terminated strings, and bytes received from C become a `Str` only through a validating library function returning `option Str`. `array` does not map directly (its references are fat); a library function exposes its base pointer. A `$func` is a **bare code pointer** — §7.3's pair does not cross, because C has nowhere to put the environment word, and rule 2 is what makes dropping it sound; a function pointer received *from* C becomes a pair whose environment is the pointer itself.

**C types the mapping cannot name.** §3.1 has one integer type, so the mapping alone can only
say `int64_t`, and a C function taking an `int`, a `size_t` or a `const char *` — every libc
function — would be declared wrongly. So `symbol` may be the C prototype itself, types only:
`$extern "int puts(const char *)" $func ($decl s 0) 0`. It is declared as written, which
agrees with any header that declares it too, with the name parenthesised so that a
function-like macro of that name is not expanded; each argument is converted to its declared
C type and the result back, so an `int` arrives sign-extended and a `void` result is unit. A
pointer is an `Int` address (§8's `str_ptr`, `box_ptr`), a reference, or a callback's code
pointer, and a pointer result is an address. The prototype and the signature must take the
same number of parameters. A type the subset of C declarators does not cover — a function
pointer parameter, say — is written through a `typedef` the build supplies.

**Rules.**
1. Extern calls are **unsafe by declaration** — the same status as `$alloc` (§4.2a). Memory returned by C is outside every frame and every allocator; wrapping it as a reference is the author's responsibility. The compiler treats every extern call as opaque.
2. **C callbacks must be capture-free.** A `$func` maps to a C function pointer only if its captured set is empty (closures capture by copy, so the set is static per literal). Captures are not in the type (§7.3), so this is a property of the *expression* in the argument position: it holds when the compiler can see which `$func` literal the value came from, and a closure arriving through a mutable function slot is rejected because it cannot be seen. Otherwise it is a compile error; pass state through the C-side `void*` argument.
3. `$extern` is the **only door to the platform**. I/O, threads, atomics, locks, files, sockets, and `malloc`-backed allocators are library code in a per-target root block.

---

## 5. Type System

### 5.1 Structural subtyping

`S <: T` when a value of `S` can be used wherever `T` is expected. Rules:

- **Base types**: `Int`, `Float`, `Str` are unrelated. `true <: Bool`, `false <: Bool`.
- **Blocks (prefix & depth)**: `S <: T` if `T`'s `$decl` fields are an ordered **prefix** of `S`'s — the same names at the same positions, each with `S_n <: T_n` — and for every prop of `T`, `S` has the same prop with the **same value**. Props are unordered, because props have no layout (§4.10).
- **Block identity**: layout *is* the type. `S <: T` and `T <: S` exactly when `S` and `T` have the same fields in the same order and the same props — so mutual subtyping is equality, and nothing is ever reordered to satisfy a coercion.

Prefix rather than unordered width, for three reasons. Subtyping stays antisymmetric, so mutual subtyping and equality coincide and a canonical form is meaningful. A supertype's fields sit at the same offsets as the subtype's, so a structural upcast never reorders and never needs an offset table: through a reference it is free and stays a thin pointer, and by value it is a copy of the supertype's fields (§7.4). And a block's field *order* becomes part of its published interface, which is checkable by reading the declaration rather than by computing a coercion.
- **Groups**: elementwise, same arity.
- **Functions**: contravariant in parameters, covariant in result.
- **Unions/intersections**: standard lattice rules. `⊥` is a subtype of everything.

Implicit coercion by subtyping is the only implicit conversion in the language.

### 5.2 Inference

Every expression has a principal type determined by its parts. Since there is no annotation syntax, inference is total. The design follows algebraic subtyping (Dolan; Parreaux's Simple-sub): unions, intersections, recursive types, and principal types with subtyping. Widening never occurs; there are no singleton literal types to widen.

### 5.3 References

```
&T  <:  &mut T  <:  &const T
```

- `$new e` yields a frame `&T`; `$alloc e` yields an allocated `&^T`. `$mut`/`$const` produce views, and preserve the kind.
- `&T` and `&mut T` are **invariant** in `T`. `&const T` is **covariant** — structural width subtyping on storage is available only through read-only views.
- `$set` requires `&mut T`. Since `&T <: &mut T`, `$set` on a bare `&T` typechecks; the `&T → &mut T` coercion is where the compiler warns: *storage used mutably without `$mut`*. The same warning fires for an unqualified `$new` in parameter position. `&T → &const T` and `&mut → &const` are silent.
- Consequence: bare `&T` is the most capable type, so a parameter `$func ($decl p $new 0)` (`&Int`) rejects `&mut Int` arguments. Idiomatic code qualifies parameters: `$mut $new 0` or `$const $new 0`.
- A lint for `$mut $new` storage that is never written through any alias is recommended.

**Kind is a second dimension**, orthogonal to the qualifier: `&^T <: &T`.
Allocated storage outlives every scope, so it is usable wherever frame storage
is — never the reverse. A parameter written `$new 0` therefore accepts either,
and one written `$alloc 0` accepts only allocated.

### 5.3a Frame storage does not escape

A frame reference is a **place**: the storage itself, in the activation whose `$new` made
it. `$decl c $new 0` binds `c` to the cell, not to a value that points at one. An
allocated reference is a **value** — a pointer — and may be copied and stored like any
other. A type is **frame-bound** if a place occurs in it — directly, in a field, or in a
closure's captures.

A place this activation made is **own**. One that came in — through a parameter, a
capture, or a name in an enclosing frame, the file's top level included — is
**borrowed**: the activation it belongs to outlives this one. Three rules follow, and
together they are the whole of it:

> **Storage never holds a place.** `$new`, `$alloc` and `$set` refuse a value that
> carries one. A place used where a value is wanted is read through (§5.4), so
> `$new $new 0` is one cell and `$set p loc` copies `loc`'s value; what is refused is
> a place carried *inside* a value.
>
> **A function's result may hold only borrowed places.** Returning a place the caller
> passed in hands it back to its owner; returning an own one is an error.
>
> **A tail call may not pass an own place.** A tail call ends the activation (§7.7), so
> its own storage ends with it. Every tail call counts, whatever the backend makes of it:
> validity may not depend on whether some other function closes a cycle.

Which places are own is a question about the source, answered by following each place to
the `$new` that made it, so nothing is annotated and nothing is solved. Because storage
never holds a place, an allocated reference never leads to one, and a frame reference
*is* one: the check never looks behind a reference. A `$func` literal that captures a
place is frame-bound, so a closure cannot carry an own place out either (§7.3). A trait
object refers to its referent (§6), and one that §6's coercion makes from a value refers
to that value's own storage — a name's slot, or fresh frame storage — so it is own when
that storage is this activation's: coercing this call's own parameter in a tail call is
the same error as passing its `$new`, and storing such an object in a cell a caller lent
is the same error as storing the `$new`.

The error is reported where the place would escape. The fix: make that storage `$alloc`
(§4.2a) and release it when done, or, for a tail call, make the call non-tail.

**Parameters.** A parameter's type cannot say whether its argument is frame-bound: a
closure's captures are not in its type (§7.3), and a trait object's kind is not in its
trait (§6). So the rule is applied to the function instead. A parameter **escapes** when
its value — or anything frame-bound it could carry, such as a closure it holds or a
value its function returns — reaches the function's result, storage that is not
frame-bound, or an escaping parameter of another call. Which parameters escape is
inferred, never written, and is part of the function's type: a function that lets fewer
of its parameters escape is a subtype of one that lets more. A frame-bound argument may
not be passed to an escaping parameter, and the error is reported at the call. A
parameter whose type is itself a place is the exception that borrowing makes: its type
does say it is frame storage, so returning it is borrowing, not escaping.

**Consequence for recursive data.** §5.5 makes a recursive value's tail storage,
so a structure that outlives the function building it must be allocated — a
list returned to a caller is built with `$alloc`, while one built and consumed
inside a single scope may use `$new` and costs nothing. This is the one place
the distinction is felt in ordinary code, and it is felt at the container, not
at every use.

### 5.4 Transparency

A reference behaves as its pointee **wherever a value is expected**: call arguments, `$match` scrutinee, projection, `$set`'s right-hand side, `$new`'s operand, overload resolution. It stays a reference where nothing expects a value: `$decl` initializers, group elements, block fields, function results. There is no explicit dereference.

A value is never implicitly converted to storage. Passing `0` to a `&Int` parameter is an error; write `$new 0`.

### 5.5 Recursion: the knot

One rule covers self-recursion, mutual recursion (`$fwd`), recursive data, and self-specializing templates.

While typing a body that refers to a name whose type is not yet known, that name has placeholder type `R`. The body's type is computed as an expression `B(R)`; the result is `μR. B(R)`, or simply `B` if `R` does not occur.

```
$decl list_of $func ($decl n 0)
  $if ($call eq (n, 0))
    {}
    { $decl head n  $decl tail $alloc ($call list_of ($call sub (n, 1))) }
```

infers `μR. {} | {head: Int, tail: &^R}` — a list type — with no declaration. Recursive data is always obtained this way.

The tail is `$alloc` rather than `$new` because the list outlives the call that
built it (§5.3a). A list that does not — built and consumed within one scope —
uses `$new` and costs nothing.

**Recursion must pass through storage.** In `μR. B`, every occurrence of `R` in `B` must sit in a position whose representation is a pointer: under a reference (`&`, `&mut`, `&const`), as an array element, or inside a function type. A block field, group element or union member holds its value inline, so `R` there would make the type's size satisfy `size(R) = … + size(R)` and no layout exists. An unguarded `R` is an error, reported at the recursive construction, and the fix is `$new` — the same rule as everywhere else: storage exists only where it was written (§4.2).

This is checked once the knot is tied, alongside the overload constraints above. Inference itself stays total; what fails is the well-formedness of the type it produced.

**Overloads on `R`**: while solving, `R` resolves overloads as if it were `⊥` (first candidate fitting the other arguments wins). The resulting constraint (e.g. `R <: Int`) is checked after the knot is tied; failure is reported at the recursive call.

**Mutual recursion**: `$fwd` slots share one system of equations.

**Templates**: specialization is memoized by argument type, and by value for compile-time generics (§4.9); hitting an in-progress entry returns its `R`.

### 5.6 Exhaustiveness and reachability

`$match` must be exhaustive (§4.7). `$match` arms and `$overload` candidates are first-fit; a later case covered entirely by an earlier one is reported as unreachable.

### 5.7 Type-only positions

Some positions hold an expression that is **never evaluated**; only its static type is used: `$match` patterns, `$try`'s pattern (§4.15), `$union` members after the first, template bounds, a parameter's default where its `$func` is written, `$extern`'s signature (§4.16), `$impl`'s trait (§4.12), and (future) the `$fwd` type operand. A default is type-only where it is written — it fixes its parameter's type there (§3.4) — and is evaluated only by a call that omits the argument, in the callee's scope. In these positions a name may be referenced while its own declaration — or an enclosing one — is still in progress. It takes the placeholder `R` and the knot of §5.5 applies. This is how recursive data types are named as bounds and defaults without a helper function, and how F-bounded template bounds work.


---

## 6. Traits

A **trait** is a collection of member signatures describing what a value can do: each member's name and type, over a distinguished type `Self`. It describes and never implements. A trait is the type of a **trait object**, and `$traitsof` (§4.13) is the form that makes one.

A **trait object** is a reference to a value together with the implementation its calls dispatch to. Its qualifier is its referent's (§3.5): one made from a value is read-only, one made from `$mut` storage is mutable. It is fully readable: `s.area` projects the member through the object, and `$call s.area ()` runs the implementation in `s`'s own table with `s`'s referent as the receiver (§4.10).

```
$decl shape_proto {
  $prop area $func () 0
}
$decl shape $traitsof shape_proto
```

`shape_proto` is an example of the shape; the trait takes its signatures and nothing else. A trait is written as the type of such an expression, the way every type in the language is: `$decl s $traitsof shape_proto` is a parameter accepting any conforming value.

- **Conformance.** A type `T` *conforms* to a trait when, for every member the trait describes, `T` has a prop of that name whose type — receiver qualifier included — is a subtype of the member's type with `T` for `Self`. Only types are compared, never values: a trait says what a value can be used for, not what it is, and a tag is a `$match` concern (§4.7). Fields are not consulted.
- **Coercion.** A trait object's type is a supertype of every type that conforms to it, and the coercion is how a trait object is made: passing `rect` where `$traitsof shape_proto` is expected makes a trait object referring to `rect` and dispatching to `rect`'s own props. This is §5.1's rule for traits and not its block rule, which compares props by value because a function-valued prop's identity is part of a block's type (§4.10); a trait object is what is used when that identity must be forgotten. The argument must be referable — a name or a reference — because a trait object refers to it, and §5.4 never turns a value into storage implicitly. A trait object takes its referent's kind as well as its qualifier: one referring to a frame binding or to frame storage is frame-bound (§5.3a).
- **Explicit conformance** is `$impl x trait override` (§4.12): a value of `x`'s type with the members added, for a type that lacks them or has no props at all. The two routes do not mix: conforming by itself means using one's own props, and `$impl` means using the props written.
- **No defaults.** A trait carries no bodies, so every member of every implementation is written for the type it implements and reads only that type's layout. Shared behaviour is an ordinary function over a trait object, which reaches its argument only through members; an implementation that wants it names it, `{ $prop describe describe }`.
- **A call dispatches through the object's own table.** `$call s.area ()` always runs `s`'s implementation on `s`'s referent. The receiver is never an argument, so it can never be another object's.
- **Another value** a member takes is typed by its parameter's default (§4.10): the declaring name for the concrete type, `$traitsof` for any conforming value. **Object safety:** a member is callable through a trait object only when `Self` appears in neither its parameters nor its result, because the referent's concrete type is erased and nothing could check that an argument has it. Such a member is still part of the trait: it must be implemented, it is callable through a bound, and a call to it through a trait object is reported at the call.
- **Implementations are not values.** An implementation is the compile-time table a coercion takes from the value's type; no program names it and no `$set` reaches it. Storage of trait type holds trait objects, so a `$set` on it replaces the reference and the implementation together, and never writes into an implementation.
- **Bounds.** A trait as a bound, `$template (T ($traitsof shape_proto))`, requires `T` to conform (§4.9). The body is specialized at `T` itself, so calls inside it are static, and a member whose signature mentions `Self` is callable there.
- **Dispatch on non-block types** uses `$impl`, or `$overload` where the set of types is closed. Extension by `$overload` is scope-based: `$decl show $overload (show_mine, show)` prepends a candidate in an inner scope.

**Composing traits.** A combined trait is the trait of a prototype listing both traits' props. There is no second mechanism.

---

## 7. Runtime Model

### 7.1 Evaluation

Strict, left to right, source order. Block initialization is source order; nothing is hoisted. A `$func` literal has no side effects.

### 7.2 Layout

A block's layout is its `$decl` (and `$fwd`) slots in source order. Props occupy no space. Groups are laid out elementwise. Layout is part of block type identity.

**A type determines its size.** Every binding is a value of a statically known type, and size follows from the type alone: a block is the sum of its slots, a group of its elements, a union the largest member plus its discriminator (§7.5), a reference one word, a `Str` two, a function two (§7.3), and a template contributes nothing until specialized, which fixes the argument types. The two constructs that would otherwise have no size are closed by rule: recursion must pass through storage (§5.5), and a function's captures are not in its type (§7.3).

So a frame's size is the sum of its slots, known at compile time, and the compiler can report it per function. Whole-program stack usage is bounded only where the non-tail call graph is acyclic — §7.7 makes tail calls cost nothing, so only non-tail recursion grows the stack, but its depth is data-dependent in general.

Nothing can point into a frame: there is no way to take a reference to a value field (§10.2) and no closure points into a dead frame (§7.3). Stack allocation of values therefore needs no escape analysis.

### 7.3 Aliasing

Storage is created only by `$new` and `$alloc`. References alias; values copy. **Closures capture bindings by copy.** Bindings are immutable, so this is unobservable: a captured binding that holds a reference still aliases the same storage. No closure ever points into a dead frame.

**A closure's captures belong to its body, not to its type.** A function's type is `params -> result` (§3.4) and says nothing about what it captured; two functions of the same type are interchangeable however they were built. Every function value is therefore represented the same way — a code pointer and an environment pointer, two words — so a function-typed slot has a size, and `$set` on storage holding a function accepts any function of that type. The body it runs changes; the type does not.

A capture-free `$func` has an empty environment and is one pointer plus a null. A capturing one needs its copies to live somewhere: the environment is frame storage of the scope the literal stood in, which is why the closure is frame-bound and §5.3a stops it escaping. A closure that must outlive that scope is written `$alloc` like any other storage that does.

### 7.4 Coercion cost

Prefix subtyping (§5.1) makes structural coercion nearly free: a supertype's fields are at the same offsets as the subtype's, so no reordering and no offset table ever arise.

- Value → block prefix supertype: a prefix copy. No field-by-field scatter.
- `&const S → &const T` with `T` a prefix supertype: **free**, and still a thin pointer.
- `&mut` never coerces structurally (invariant), so it is always a thin pointer.
- Member → union: a discriminator write and a copy of the member.
- **Union → union**: one `case` per source member, each writing the target's position and moving the payload — a branch, not a copy, because §3.6 makes a union a set and §7.5 makes the position the discriminator, so the two need not agree. Where the source's members are a prefix of the target's canonical order the map is the identity and the branch is a copy.
- `μR. B` ↔ its unrolling: free. They are one type (§5.5) and two terms, so the backend emits one as an alias of the other.
- From `⊥`: nothing. The code is unreachable.
- A reference's **kind** (§3.5) costs nothing at runtime: frame and allocated references are both thin pointers, and the distinction exists only to be checked.
- **Fat references remain only for trait objects** (§6): two pointers, the referent and its implementation. The implementation is emitted statically. Coercing a conforming value to a trait object costs the pair, not a copy of the value; the table exists because a trait's props are function implementations, not because of layout. The receiver is passed at the call; the table holds no captures.

### 7.5 Runtime type information

Values of union type carry a discriminator so `$match` can test them. **Which position a member takes is canonical**: §3.6 makes a union a set with no intrinsic order, so the members are ordered by a rule the compiler fixes, and a member's discriminator is therefore a function of the member set alone — not of the order the members were written in, and not of where else in the program the same union appears. Nothing observable depends on the numbering: a program names members, never tags. Blocks differing only in props are distinguished by that discriminator; no other construct reads it.

### 7.6 Memory: two kinds of storage, no collector

Only `$new` and `$alloc` allocate, and there are no references into value
fields, so storage is the only thing to manage — and which kind of storage a
reference names is in its type (§3.5).

**Frame storage** (`$new`) is a place (§5.3a) in the activation that made it, and is
released when that activation ends: when its function returns, or when a tail call
replaces it (§7.7). A file's top level is the outermost frame, and its activation is the
whole program, so a top-level `$new` lives as long as the program does — `$new` means the
same in every frame. There is no allocator, no header, no bookkeeping and no runtime
component. Each `$new` site runs at most once per activation, since repetition is
recursion and every step of it is an activation of its own, so its storage is simply a
slot of the frame. It is safe because §5.3a confines places: storage never holds one, a
function returns only places that came in, and a tail call passes none its activation
made. Nothing is annotated; the one fact inferred — which places an activation made — is
read off the source, by following each place to the `$new` that made it.

**Allocated storage** (`$alloc`) comes from `allocator`, an ordinary name resolved
lexically and in source order (§4.10) at the point `$alloc` is written: the root block
declares the default for a target, and `$decl allocator …` in a block overrides it for
what is written after it there. An allocator is any value with a member
`$prop alloc $func ($decl size 0) 0`, which is asked for `size` bytes and answers their
address (§8's raw memory); by convention it also has `free`, taking an address back. The
root's are `raw_alloc` and `raw_free`; an arena's `free` does nothing, and it releases
everything at once. `$alloc e` asks the allocator for the storage `e`'s value needs and
stores the value there. An allocator releases when the author says so, which makes
`$alloc` **unsafe by declaration** — the same status as `$extern` (§4.16). A reference
used after its allocator released it is the author's error.

Because the name is resolved where `$alloc` is written, rebinding `allocator` does not
reach into a library: a list's cells written in the prelude come from the prelude's
allocator, whatever its caller has bound. A library whose storage should come from its
caller's allocator takes the allocator as a template generic (§4.9), and a build program
can replace the root's for a whole program (§9). That is the price of no implicit
parameters, and it is paid at the library, which says so in its signature.

The division is deliberate: the common case is free and safe, and everything that
outlives an activation is written down. There is no garbage collector, no region
inference, no implicit region parameters, and no lifetime syntax — the type system
carries only which of two kinds a reference has.

References do not record *which* allocator; mixing across allocators is on the
author.

Arrays: `at` returns a fat reference (base + index) rather than an interior
pointer, of the same kind as the array.

### 7.7 Tail calls

Loops are recursion; **tail-call elimination is mandatory**. Tail positions: a `$func` body, each arm of a `$match` in tail position, and the second operand of a `$do` in tail position, transitively. A call inside a block is never in tail position (the block's value is its environment); use `$do`.

### 7.8 Effects and concurrency

**No effect types.** A function's type says nothing about what it does. Evaluation is strict, left to right. The only compile-time/runtime distinction is `$prop` vs. everything else.

**No concurrency in the language.** Threads, atomics, and locks come from C through `$extern` (§4.16) and are wrapped by library code. The compiler contributes exactly one thing: the bound **`sendable`**, a root-block prop it understands natively, satisfied by a type that contains no reference other than the synchronization types the target's root block designates. Library `spawn`, `channel`, and `join` are declared with `$template (T sendable)`; anything new that crosses a thread boundary uses the same bound.

Consequences:
- Values cross threads **by copy**. `&const` gets no exception (it may alias another thread's `&mut`). Sharing is always explicit through synchronization storage.
- A thread's storage is its own: no thread holds a reference into another's frame, and messages are copied. A shared allocator is the author's business, like any other `$alloc` (§7.6).
- The build program chooses the runtime: a single-threaded target's root block may run `spawn` inline or omit it, and the checker reports which modules needed it.
- **Panics abort the whole program** from any thread. There is no catch and no cancellation.

---

## 8. Primitives

Every program is wrapped in an implicit **root block**, assembled by the build program per target. It has two layers.

**Intrinsics** — things the language cannot express and the compiler implements:

| Group | Names | Notes |
|---|---|---|
| Numeric | `add sub mul div mod neg lt` | each `$overload` over `(Int,Int)` and `(Float,Float)`; no implicit conversion. On `Int`, overflow and `div`/`mod` by zero panic, and `mod` by `-1` is `0`. On `Float` they are IEEE 754: `div` by zero is an infinity (NaN for `0.0 / 0.0`), `mod` by zero is NaN, `mod` takes the dividend's sign, and `lt` is false whenever an operand is NaN |
| Numeric, explicit | `add_wrap sub_wrap mul_wrap add_sat sub_sat mul_sat` | wrapping (two's complement, modulo 2^64) / saturating (clamped to `Int`'s range) `Int` arithmetic; never panic |
| Bitwise | `band bor bxor shl shr` | on `Int`'s two's complement bits. `shl (x, n)` discards the bits shifted out and `shr` is arithmetic, copying the sign bit in; a count `n` outside `0..63` panics |
| Conversion | `to_float to_int to_str` | `to_int` overloaded: `Str -> option Int`, `Float -> option Int` (truncates toward zero; `none` if out of range or NaN). From a `Str` it accepts exactly §2.1's integer literals — an optional `-`, then decimal digits, in range — so `+5`, `1_000` and ` 5` are `none` |
| Equality | `eq` | overloaded over `Int Float Str Bool`; structural equality on blocks is a trait. On `Float` it is IEEE equality — NaN is not equal to itself and `0.0` equals `-0.0` — so `eq` is not reflexive on `Float`, and an equality built from it over a block with a `Float` field inherits that |
| Strings | `concat len slice byte` | **byte** units. `byte (s, i)` reads one byte as `Int`. `len` counts bytes; `slice (s, i, j)` takes byte offsets and panics if an offset splits a code point, preserving the validity invariant. Code-point and grapheme iteration are library; `eq` is bytewise (equal to code-point equality under the invariant) |
| Arrays | `array at alen` | `$call array (n, example)` → `&mut [T]`, contiguous, bounds-checked; `at` → fat `&mut T` (or `&const T` through a `&const` array); length not part of the type |
| Control | `panic` | returns `⊥`; aborts, no catch |
| Shapes | `err none` | patterns for `$try` |
| Bounds | `sendable` | compiler-known template bound (§7.8) |
| FFI | `str_ptr str_from_ptr array_ptr box_ptr unbox raw_alloc raw_free` | raw addresses for `$extern` and for allocators written in the language (§7.6), each an `Int` (§3.1 has one integer type): `str_ptr (s)` and `array_ptr (a)` give the base of the bytes or elements (a `Str` is not NUL-terminated, so its length travels separately); `box_ptr (r)` takes the address of storage, which must be a reference; `unbox (addr, example)` recovers a reference typed by the example — allocated and writable, since what it points at is outside every frame. `str_from_ptr (addr, n)` is the way back for bytes: it copies `n` bytes from the address and answers `option Str`, `none` when they are not valid UTF-8 or `n` is negative — the validating function this section's ABI mapping requires. `raw_alloc (n)` answers the address of `n` fresh bytes, 0 when none is to be had, and `raw_free (addr)` releases one; they are the root `allocator`'s `alloc` and `free`. All unsafe by declaration |
| Build | `compiler` | see §9 |

**Platform** — library code over `$extern`, present per target: `print`, `read`, files, sockets, `spawn`/`join`/`channel`/`mutex`/`atomic`, `malloc`-backed allocators. The root block defines `option` and `result` before any of these so failing operations return them; `Int` arithmetic (overflow, `div` by zero) and `slice` out of range panic. `Float` arithmetic does not: its failures are values (§3.1), and the program meets them where a `Float` becomes an `Int`, since `to_int` answers `none` for NaN and out-of-range values.

Everything else — `not`, `and`, `or`, `max`, lists, maps, formatting — is library code. Sanity check that the core suffices:

```
$decl not $func ($decl b $union (true, false)) $match b ($case true false, $case false true)
```

infers `Bool -> Bool`.

The `$union` is load-bearing. §3.4 makes a parameter's default *fix* its type and §3.2 makes `true` a tag type of its own, so `$func ($decl b true)` would accept `true` and nothing else. Giving a parameter a union type without a runtime branch is exactly what §4.8a describes `$union` as being for.

---

## 9. Build and Test

**There is no configuration language.** The toolchain evaluates a designated file (`build`) as an ordinary program and reads the block it produces. Everything else is library code consuming values.

- **The compiler is a library**: the root-block value `compiler` exposes `parse`, `check`, `verify`, `emit`, `link`, the typed tree it passes between them (§9.1), and props describing host and targets. A build file is a block that calls them.
- **Staged, not interleaved.** The build program runs *before* compiling the target. There is no compile-time execution inside a program; templates and props are the only compile-time constructs.
- **Tests are a structural interface**: any block conforming to `$traitsof {$prop name ""  $prop run $func () true}` (§6). Metadata is props (`$prop tags ("slow", "net")`). The runner is library code.
- **No in-language reflection.** `$call compiler.parse` returns an AST as a block; a build program that wants discovery walks it and generates a runner source. Reflection lives in the compiler library at build time.
- **Dependencies are in code, resolution is in the build.** `$import` (§4.14) declares the graph; the build program provides the resolver and picks entry files. It never assembles the graph by hand, but it can override any edge, inject names into the root block, or specialize a template module.
- **No macros / conditional compilation.** Environment selection is either an import override in the build (swap which file `"net"` resolves to) or a `$template` over a config block that the build specializes. Unused branches are dead by type (matching on prop values) and still type-checked.

```
$decl net $template (Cfg { $prop tls true  $prop backend "epoll" }) {
  … $match Cfg ($case {$prop backend "epoll"} …, $case {$prop backend "kqueue"} …) …
}
```

### 9.1 The pipeline is a value at every step

`parse`, `check` and `emit` are separate calls over values, not one opaque
build:

```
parse   : (Str, path)  -> { $decl ast … $decl path … $decl base … $decl diagnostics … }
check   : parsed       -> { $decl program … $decl diagnostics … }
verify  : program      -> diagnostics
emit    : program      -> { $decl files … $decl diagnostics … }   // one entry per output: { $decl path … $decl text … }
link    : (emitted, …) -> { $decl path … $decl diagnostics … }
```

Every step that can fail carries its diagnostics beside its result rather than
raising: §4.15 makes an expected failure a value, and a step that stopped still
has to hand the next one something of the right shape. `verify` is the one that
cannot fail, because it *is* the diagnostics. The path travels with the text
because a diagnostic names its own file and `$import` resolves relative to the
entry (§4.14) — the caller is not asked to remember it.

`emit` answers **a list** of outputs and not a single text, because §4.14 makes a
file a unit the compiler can keep: a target may want one output per source module
so that an unchanged module need not be translated again, and a target that wants
a single artifact simply gets a list of one. Each entry carries the `path` it
should be written to, relative to wherever the build program puts it, for the
same reason `parse` takes one — the caller is not asked to invent names for the
compiler's own outputs. Whether a symbol may be referenced from another output is
the target's question, not the language's: §4.14 already says what a module can
name, and the mapping onto a linker's notion of internal and external linkage
belongs with §4.16's ABI mapping.

`program` is the **typed tree**: names resolved to frame slots, projections as
layout positions (§7.2), §5.4's implicit dereferences written out, tail position
marked (§7.7), and types interned so an index names one layout. It is an
ordinary block, built by ordinary constructors, and `compiler.program` is an
example value of it — types are still never written, only exemplified (§5.7).

The project-level form is a convenience over these, not a separate mechanism:

```
$decl app $call compiler.emit ({
  $decl entry   "src/main"
  $decl roots   ("src", "lib")
  $decl resolve { $prop net "src/net_kqueue" }     // overrides `$import "net"` for this target
  $decl target  compiler.host
})
```

### 9.2 An optimisation is a library

A pass is an ordinary function from `program` to `program`, and a pipeline is
ordinary composition:

```
$decl build {
  $decl src  $call compiler.parse (…)
  $decl ckd  $call compiler.check (src.ast)
  $decl opt  $call my.inline ($call my.fold (ckd.program))
  $decl app  $call compiler.emit (opt)
}
```

There is no registry, no hook and no discovery, for the same reason there is no
configuration language: pass order is the order the calls are written, and a
conditional pass is an `$if`. A project that wants none simply does not call
any, and one that wants its own pins them like any other dependency.

This does not reopen macros or reflection (§9's list above). A pass runs in the
*build* program, which executes before the target is compiled; nothing here
executes inside the program being compiled.

**A pass is ordinary code, so it can be wrong.** `verify` type-checks a
`program` and returns diagnostics, which is how a pipeline finds out. Running it
is the build program's choice — mandatory after every pass while developing one,
and usually not in a release build.

**The compiler never assumes a pass ran.** There is no optimisation level and no
canonical pipeline, so `emit` must stay correct on unoptimised input. That is a
deliberate constraint on the compiler, not an omission.

### 9.3 What exposing the tree commits to

`program`'s shapes become a compatibility surface. §10.9 already makes a block's
field order part of its interface — a field may be added compatibly only at the
end, and reordering breaks every supertype that named the fields. Exposed, that
binds every pass in every project rather than only the compiler's own modules.
The exposed tree is therefore deliberately smaller than whatever the compiler
uses internally, and is expected to change rarely and only by extension.

Two consequences, the first of which is easy to get wrong:

- **A pass's annotations do not survive the compiler.** Adding a field to the
  end of a node makes a subtype, which the compiler's functions accept — but
  §7.4 makes that coercion a *prefix copy*, so the extra field is dropped on the
  way in. Analysis results therefore live in the pass's own structures, carried
  from pass to pass directly, not smuggled through the tree. (Making the
  pass-facing functions `$template`s bounded by the node type would preserve
  them, at the price of every such function becoming generic; that is deferred,
  see §11.)
- **A node has an index of its own**, distinct within a program, and that is
  what a side table keys on. It sits beside the type as the second field of
  every node, so a pass reads it without knowing the shape. Indices are handed
  out in construction order, which the paragraph below makes binding: a pass may
  compare two of them for equality and may use one as a table key, but may not
  read anything into their order or their density.

**Determinism is part of the interface.** The bootstrap's final gate is that a
compiler compiling itself twice produces byte-identical output. With passes in
the pipeline that requirement covers the build program too: a pass that iterates
a hash or depends on allocation addresses breaks it, and the break shows up as a
bootstrap failure rather than a wrong answer.

Consequence: the compiler must be callable from the language from day one (self-hosted or bound), and every target needs a root block — which is mostly `$extern` declarations and wrappers.

---

## 10. Expected Implications

These follow from stated rules and are accepted by design:

1. A block's value is its environment; a trailing expression is discarded.
2. `$set p.x` works only if `x` was declared with `$new`; there is no way to take a reference to a value field.
3. Narrowing in `$match` on a `&mut` reference is exact; writes are allowed inside the arm.
4. Recursive return types are inferred, so adding a base case changes the function's type and errors surface at call sites.
5. No hoisting: a `$func` referencing a later non-`$func` name is an error; use `$fwd` for mutual recursion among functions.
6. Overload and match order is semantic (first fit); reordering can change meaning, mitigated by the unreachable lint.
7. Template bodies are checked only at specialization.
8. Bare `&T` in parameter position rejects `&mut` arguments; qualify parameters.
9. Structural upcasts are free and stay thin pointers, because a supertype is a prefix. The price is paid at declaration instead: **field order is part of a block's interface**. A field may be added compatibly only at the end, and reordering fields is a breaking change for every supertype that named them.
10. `$traitsof` abstracts by structural type equality, so any parameter whose type equals the source block's type becomes `Self`.
11. A recursive type whose recursion does not pass through storage is an error rather than an inferred type (§5.5), so `$new` appears in every recursive data constructor — the library's `list` included. This is the price of `$new` being the only allocation in the language.
12. A function's type does not record its captures (§7.3), so **capture-freeness is a property of an expression, not of a type**. §4.16's C-callback rule is checkable exactly when the compiler can see which `$func` literal a value came from; a closure reaching a callback parameter through a mutable function slot cannot be checked and is rejected.
13. An implementation is always a static table: its members are props, and a prop cannot capture (§4.10). The receiver is an implicit parameter, passed at the call, and a trait object's only runtime part is its reference.
14. Storage that outlives the scope it was made in must be written `$alloc`, so a container returned to a caller names an allocator (§5.3a) while one used within a scope is free. The cost lands at the container, not at every use.
15. There is no optimisation level and no canonical pass pipeline (§9.2), so `emit` must stay correct on unoptimised input and no pass may be assumed to have run. The cost of "optimisation is a library" is paid by the compiler, not by the user.
16. Frame storage is safe by construction and allocated storage is **unsafe by declaration**: the language guarantees a frame reference never dangles, and says nothing about an allocated one after its allocator released it. There is no collector, and the one thing inferred — which places an activation made — is read off the source (§5.3a). A tail call may not pass storage its activation made, so a loop that hands storage on writes it `$alloc` and releases it.

---

## 11. Deferred / Open

- Whether the pass-facing compiler functions should be `$template`s bounded by the node type (§9.3), so that a pass's own annotations survive a call into the compiler instead of being prefix-copied away (§7.4). It is the difference between passes carrying analysis beside the tree and inside it.
- Whether a *library* allocator can be made safe rather than unsafe by declaration — some form of scoped allocator whose references cannot outlive it, which would be §5.3a's rule generalised from the frame to any allocator. Deliberately not attempted: it is the step from two kinds to arbitrarily many, and that is a lifetime system.
- Growable vector over `array` (library).
- Variadic templates (abstraction over group arity).
- Whether `&mut S` may widen to a prefix supertype `&mut T`. Under prefix layout a write through the narrowed view leaves `S`'s tail intact, so width (not depth) coercion looks sound; §5.3 keeps `&mut` invariant for now.
- `$fwd (name, example)` — optional type operand, must be a group.
- `static` — per-type mutable storage, deliberately distinct from `$prop`.
- Specializing with an overload argument producing an overloaded result (currently an error).
- Standard library: `list`, `map`, structural `eq`, `and`/`or`, formatting.

---

## 12. Worked Examples

**Counter and aliasing**

```
$decl n $mut $new 0
$set n ($call add (n, 1))     // n : &mut Int, derefs in add
$decl y n                    // alias
$decl z $new n                // copy
```

**Tagged blocks and match**

```
$decl circle { $prop kind "circle"  $decl r $new 1.0 }
$decl square { $prop kind "square"  $decl w $new 2.0 }
$decl area $func ($decl s $union (circle, square)) $match s (
  $case {$prop kind "circle"} $call mul (3.14, $call mul (s.r, s.r)),
  $case {$prop kind "square"} $call mul (s.w, s.w)
)
```

**Mutual recursion with `$fwd`**

```
{
  $fwd odd
  $decl even $func ($decl n 0) $if ($call eq (n, 0)) true  ($call odd  ($call sub (n, 1)))
  $decl odd  $func ($decl n 0) $if ($call eq (n, 0)) false ($call even ($call sub (n, 1)))
}
```

**A list, from scratch**

```
$decl list $template T {
  $prop nil  { $prop tag "nil" }
  $prop node $union (nil, { $prop tag "cons"  $decl head T  $decl tail $new node })
  // The tail is storage (§5.5), so `cons` takes a reference and keeps it —
  // `$new tail` would deref and copy the whole list (§4.2).
  $prop cons $func ($decl head T, $decl tail $new node) { $prop tag "cons"  $decl head head  $decl tail tail }
  $prop fold $template A $func ($decl xs node, $decl acc A, $decl f $func ($decl a A, $decl x T) A)
    $match xs (
      $case {$prop tag "nil"} acc,
      $case {$prop tag "cons"} $call fold (xs.tail, $call f (acc, xs.head), f)   // A inferred
    )
  $prop map $template U $func ($decl xs node, $decl f $func ($decl x T) U) {     // U inferred from f
    $decl lu $specialize list U
    $decl r $call fold (xs, lu.nil, $func ($decl acc lu.node, $decl x T) $call lu.cons ($call f (x), acc))
  }.r
}
```

**A loop**

```
$decl while $func ($decl cond $func () true, $decl body $func () {})
  $if ($call cond ()) ($do ($call body ()) ($call while (cond, body))) {}
```

**Error propagation**

```
$decl parse_pair $func ($decl s "") {
  $decl a $try ($call to_int ($call slice (s, 0, 1))) none
  $decl b $try ($call to_int ($call slice (s, 1, 2))) none
  $decl r $call ($specialize option (0, 0)).some ((a, b))
}.r
// inferred: Str -> none | some (Int, Int)
```

**Generic identity and inference**

```
$decl id $template T $func ($decl x T) x
$call id 5                    // T inferred as Int
$specialize id "s"            // explicit, yields Str -> Str
```

**Overload as type-level switch**

```
$decl show $overload (
  $func ($decl b true) $if b "yes" "no",      // specific first
  $func ($decl n 0)    $call to_str (n)
)
$call show true               // picks candidate 1
```

**Traits: conformance, coercion, `$impl`**

```
$decl shape_proto { $prop area $func () 0 }

// `rect`'s members reach their receiver by the declaring name.
$decl rect { $decl w 3  $decl h 4
  $prop area $func () $call mul (rect.w, rect.h) }
$decl sq   { $decl side 5
  $prop area $func () $call mul (sq.side, sq.side) }

// Both conform, so each coerces to a trait object at the call.
$decl total $func ($decl a $traitsof shape_proto, $decl b $traitsof shape_proto)
  $call add ($call a.area (), $call b.area ())
$call total (rect, sq)                                   // 37

// Shared behaviour is a function over the trait object, not a default.
$decl describe $func ($decl s $traitsof shape_proto)
  $call concat ("area=", $call int_to_str ($call s.area ()))
$call describe (rect)                                    // "area=12"

// `Int` has no props. `$impl` gives this value the members; the `$decl` over it names the
// receiver, and the value is still an `Int`. The receiver is a reference (§4.10), so the
// member reads it where a value is expected (§5.4) rather than returning it.
$decl n   7
$decl n_s $impl n ($traitsof shape_proto) { $prop area $func () $call add (n_s, 0) }
$call describe (n_s)                                     // "area=7"

// Storage of trait type holds trait objects; `$set` replaces the whole object.
$decl cur $mut $alloc $traitsof shape_proto
$set cur rect
$set cur sq

// Another value of the receiver's own type: the declaring name, in a type-only position.
// `longer` mentions `Self` once traited, so it is callable through a bound, not a trait object.
$decl seg { $decl len 2
  $prop longer $func ($decl other seg) $call lt (other.len, seg.len) }
```

**A bound: conformance checked, calls static**

```
$decl doubled $template (T ($traitsof shape_proto)) {
  $prop run $func ($decl v $const $new T) $call mul ($call v.area (), 2)
}
$call ($specialize doubled rect).run (rect)              // 24; `v.area` is a direct call
$specialize doubled n                                    // error: `n` is an Int, which does not conform
```
