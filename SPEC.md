# morphl — Language Specification (Draft 4)

*Status: core semantics, memory model, FFI, and syntax closed. Remaining items are listed in §11.*

---

## 1. Philosophy

- **Everything is an expression.** There are no statements. Blocks, declarations, functions, matches, and templates all evaluate to values.
- **Static types, inferred from expressions.** There is no syntax for writing a type. A type is always the type *of some expression*. Where a type is needed as a bound or pattern, an example expression is written and only its type is used.
- **Structural, never nominal.** Two values are compatible when their shapes are compatible. No type is declared; no conformance is declared. Subtyping is the only implicit coercion.
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
| `$impl T trait override` | 3 | block, trait template, block of props (`{}` if none) |
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

`Int` (64-bit; **overflow panics**; wrapping and saturating forms are explicit intrinsics), `Float` (64-bit), `Str` (immutable, pointer + length, **always valid UTF-8**). There is no character type: a character is a one-code-point substring.

Literals have their base type: `0 : Int`, `"hi" : Str`. There are no singleton literal types.

### 3.2 Booleans

`true` and `false` are two distinct **nullary tag types**. `Bool` is the union `true | false`. They are the only literals that are types; conceptually they are the language's one built-in sum type, and `$if` is `$match` over them.

### 3.3 Blocks

A block `{ … }` is a scope. Its **value** is the collection of its `$decl` slots; its **type** is the ordered list of `(name, type)` for those slots plus its props.

- `$decl` fields are **ordered** and form the block's **layout**, in source order.
- `$prop` fields are in the namespace and type but **not** in the layout (§4.10).
- Non-`$decl` expressions in a block run for effect and are discarded.

A block never yields "the last expression." To compute and return a value: `{ … $decl r e }.r`.

Blocks are also records, modules, namespaces, and (when made of props only) traits. A source file is a block.

### 3.4 Functions

`$func params body`. `params` is a group of `$decl`s; each default fixes the parameter's type. Parameters are ordinary declarations (immutable bindings). Defaults are evaluated at call time when the argument is omitted.

A function's type is `params -> result`, where `result` is the type of `body`.

### 3.5 References

`&T`, `&mut T`, `&const T` — storage holding a `T`. See §5.3.

Storage also has a **kind**, fixed where it is created and carried in its type:

- **frame** storage (`$new`, §4.2) lives in the enclosing scope and is released
  when that scope exits. It is free — no allocator, no bookkeeping — and it may
  not outlive the scope that made it (§5.3a).
- **allocated** storage (`$alloc`, §4.2a) comes from an `allocator` and lives
  until that allocator releases it. It may outlive anything.

The kind is written `&T` for frame and `&^T` for allocated *in diagnostics only*
— there is still no syntax for writing a type (§1). Which kind an expression has
follows from which form created the storage.

### 3.6 Unions, intersections, bottom

Types form a lattice with `|` (union) and `&` (intersection), and `⊥` (bottom, the type of `panic`). Unions arise from `$if`/`$match`, recursion, and the `$union` form (§4.8a); there is still no type syntax — `$union` takes example expressions.

### 3.7 Overloads and templates

An `$overload` is a group whose static type records "resolve by index" (§4.8). A `$template` is a compile-time abstraction (§4.9). Both are ordinary values that can be bound with `$decl`.

---

## 4. Forms

### 4.1 `$decl name e`

Binds `name` to the value of `e`. The binding is immutable and its type is exactly the type of `e`. Evaluates to the value.

Inside a block, `$decl` also adds an ordered slot to the block.

Scope: `name` is visible from this point onward in the enclosing block. Additionally, when `e` is a `$func`, `$template`, or block, `name` is in scope **inside `e`** (self-reference), subject to the rule that it may only be *read* from inside a `$func` body — i.e., not while `e` itself is still being evaluated.

In *type-only positions* (§5.7) a name may be referenced while its own declaration is still in progress.

`$decl x 0` is permitted but unnecessary; a value that will vary should be `$new`, a constant should be `$prop`.

### 4.2 `$new e`

Allocates storage holding the value of `e` and evaluates to a reference `&T`, where `T` is the type of `e`. If `e` is itself a reference, it is dereferenced first (so `$new r` is a copy, not an alias).

`$new` makes **frame** storage: it lives in the enclosing scope and is released
when that scope exits, at no cost and with no allocator. In exchange it may not
escape that scope — see §5.3a, which is what makes the release safe without any
inference or runtime.

`$new` and `$alloc` (§4.2a) are the **only** ways storage comes into existence. A
`$decl` never creates a cell.

### 4.2a `$alloc e`

Allocates storage holding the value of `e` from the `allocator` in lexical scope
(§7.6) and evaluates to a reference `&^T`. As with `$new`, a reference operand is
dereferenced first.

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

1. Evaluates each argument **once** and binds it to the corresponding generic name, as if `$decl T arg` were prepended to `body` (substitution by reference, never textual — side effects happen once).
2. Types the resulting expression with ordinary rules.
3. Has exactly the type of that expression.

Typing is memoized per **argument type**; instantiation (value binding) is per specialization. Two specializations with the same argument type share typing but not necessarily values.

**Bounds.** A generic name may carry an example: `$template (T bound) body`. The bound is a type-only position (§5.7), so it may mention `T` itself — `$template (K ($specialize equatable K))` is the F-bounded form. At specialization, `type(arg) <: type(bound)` is checked first and reported as such. The body is still typed *after* substitution; the bound is a precondition, not a proof that all conforming arguments typecheck.

**Application infers `T`.** If a template's body is a `$func`, then `$call t args` means `$call ($specialize t inferred) args`. Inference matches the **shape of each parameter default one level deep**:

- default is exactly `T` → `T` is the argument's type;
- default is a `$func` literal whose parameter defaults or body are exactly `T` → `T` is the corresponding parameter or result type of the argument's function type.

Nothing deeper is inferred (no unification through arbitrary expressions); use `$specialize` explicitly. If `T` is inferred from several places, the first in parameter order wins and the rest are checked against it. A recursive call inside the template's own body uses the same rule, so `$call fold (xs.tail, acc2, f)` re-specializes on `acc2`'s type without writing `$specialize`.

**Self-specialization** (`$decl list $template T { … $specialize list T … }`) ties the recursion knot via memoization on the argument type (§5.5). A chain of *distinct* argument types is unbounded; there is a fixed instantiation depth limit and exceeding it is an error.

Specializing with an overload argument is an error; resolve first.

### 4.10 `$prop name e`

Declares a **compile-time constant** member of the enclosing block. `e` must be fully evaluable by the compiler: a literal, `true`/`false`, a `$func`/`$template` literal, a block made only of props, or one of the compile-time forms `$overload`, `$union`, `$specialize`, `$impl`, `$traitsof`, and projection of a prop. Never `$new`, never `$call`.

**Props are visible throughout their block**, regardless of order, and are typed together as one system (§5.5). Props have no layout, so the no-hoisting rule (§4.11) does not apply to them.

- A prop is in the block's namespace and **type**, not its layout. It costs no slot.
- **A prop's value is part of the enclosing block's type.** `{$prop kind "circle"}` and `{$prop kind "square"}` are different types. This is the only place a value appears in a type, and it is how tags work.
- A prop initializer may reference other props and enclosing scopes, but not ordered siblings (there is no instance to read them from). A prop function reaches instance fields through an explicit receiver parameter.
- Access is uniform: `p.len` and `point.len` both work.

### 4.11 `$fwd name`

Reserves an **ordered slot** at this position in the block with a placeholder type `R_name`. Exactly one later `$decl name e` in the same block completes it: `e` is typed with `name : R_name`, the knot is tied (§5.5), and the slot takes the resulting type.

- References to `name` before its completing `$decl` are allowed only inside a `$func` or `$template` body.
- A `$fwd` not completed by the end of its block is an error.
- Layout position is the `$fwd`, not the `$decl`.
- `$fwd` promises a slot; it is never used in traits (§6).

Future extension: an optional type operand must be written as a group, `$fwd (name, example)`, to preserve fixed arity.

There is **no hoisting**. Initialization order is source order. Mutual recursion uses `$fwd`.

### 4.12 `$impl T trait override`

Assembles a **witness**: a block of props conforming to `$specialize trait T`. For each prop declared by the trait, the value is taken with precedence:

1. `override` (a block of props; must be `{}` if empty),
2. `T`'s own prop of that name,
3. the trait's default.

Every result must be a subtype of the trait's declared prop type. A prop in `override` that the trait does not declare is an error. Inside `override`, the trait's other members are in scope by name, resolved against the final collection.

`$impl` evaluates to the witness, a compile-time block. It is the explicit statement "T implements trait", a first-class dictionary, and the table used by `&const` fat references (§7.4).

There is no registration and no coherence problem: a witness is just a block.

### 4.13 `$traitsof e`

Derives a trait from a concrete block `e`: a `$template Self` whose props are `e`'s props with every occurrence of `e`'s type in those props' types replaced by `Self`, and `e`'s bodies as defaults. Substitution is structural (any parameter or field whose type equals `e`'s type becomes `Self`). Ordered fields never appear; traits promise no slots.

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

**ABI mapping.** A block is a C struct in `$decl` order (props cost nothing; they are not present at runtime). Groups likewise. `&T` and `&mut T` are thin pointers (`T*`); `&const T` may be fat, so only exact-type references cross — coerce before the call. `Int` → `int64_t`, `Float` → `double`. `Str` is pointer + length; a library `cstr` adapter produces NUL-terminated strings, and bytes received from C become a `Str` only through a validating library function returning `option Str`. `array` does not map directly (its references are fat); a library function exposes its base pointer.

**Rules.**
1. Extern calls are **unsafe by declaration** — the same status as `$alloc` (§4.2a). Memory returned by C is outside every region; wrapping it as a reference is the author's responsibility. The compiler treats every extern call as opaque.
2. **C callbacks must be capture-free.** A `$func` maps to a C function pointer only if its captured set is empty (closures capture by copy, so the set is static per literal). Captures are not in the type (§7.3), so this is a property of the *expression* in the argument position: it holds when the compiler can see which `$func` literal the value came from, and a closure arriving through a mutable function slot is rejected because it cannot be seen. Otherwise it is a compile error; pass state through the C-side `void*` argument.
3. `$extern` is the **only door to the platform**. I/O, threads, atomics, locks, files, sockets, and `malloc`-backed allocators are library code in a per-target root block.

---

## 5. Type System

### 5.1 Structural subtyping

`S <: T` when a value of `S` can be used wherever `T` is expected. Rules:

- **Base types**: `Int`, `Float`, `Str` are unrelated. `true <: Bool`, `false <: Bool`.
- **Blocks (prefix & depth)**: `S <: T` if `T`'s `$decl` fields are an ordered **prefix** of `S`'s — the same names at the same positions, each with `S_n <: T_n` — and for every prop of `T`, `S` has the same prop with the **same value**. Props are unordered, because props have no layout (§4.10).
- **Block identity**: layout *is* the type. `S <: T` and `T <: S` exactly when `S` and `T` have the same fields in the same order and the same props — so mutual subtyping is equality, and nothing is ever reordered to satisfy a coercion.

Prefix rather than unordered width, for three reasons. Subtyping stays antisymmetric, so mutual subtyping and equality coincide and a canonical form is meaningful. A supertype's fields sit at the same offsets as the subtype's, so every structural upcast is free and stays a thin pointer (§7.4). And a block's field *order* becomes part of its published interface, which is checkable by reading the declaration rather than by computing a coercion.
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

A type is **frame-bound** if a frame reference occurs anywhere in it — directly,
in a field, behind another reference, or in a closure's captures. Frame-bound
values are confined by one rule:

> A frame-bound type may not appear in a function's result, and a frame-bound
> value may not be written into storage that is not itself frame-bound.

That is the whole of it, and it is a structural check on types already inferred
— no lifetime variables, no annotations, nothing to solve. A `$func` literal
that captures a frame reference is itself frame-bound, so a closure cannot carry
one out either (§7.3).

The error is reported where the value would escape, naming the `$new` it came
from. The fix is always the same: make that storage `$alloc` (§4.2a).

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

**Templates**: specialization is memoized by argument type; hitting an in-progress entry returns its `R`.

### 5.6 Exhaustiveness and reachability

`$match` must be exhaustive (§4.7). `$match` arms and `$overload` candidates are first-fit; a later case covered entirely by an earlier one is reported as unreachable.

### 5.7 Type-only positions

Some positions hold an expression that is **never evaluated**; only its static type is used: `$match` patterns, `$union` members after the first, template bounds, and (future) the `$fwd` type operand. In these positions a name may be referenced while its own declaration — or an enclosing one — is still in progress. It takes the placeholder `R` and the knot of §5.5 applies. This is how recursive data types are named as bounds and defaults without a helper function, and how F-bounded template bounds work.


---

## 6. Traits

A **trait** is a template over `Self` whose body is a block containing only props, each with a default:

```
$decl shape $template Self {
  $prop area $func ($decl s $const $new Self) 0.0
  $prop describe $func ($decl s $const $new Self)
    $call concat ("area=", $call to_str ($call area (s)))
}
```

- **Interface satisfaction is subtyping**: `T` satisfies `shape` iff `T <: $specialize shape T` (F-bounded). A template bound of `($specialize shape T)` requires the *whole collection* with fixed signatures.
- **Explicit conformance** is `$impl T shape override` (§4.12), which yields a witness.
- **Required members**: every prop has a default. A member that must be overridden uses a panicking default whose return value fixes the signature:
  `$prop area $func ($decl s $const $new Self) { $call panic ("unimplemented")  $decl r 0.0 }.r`
- **Dispatch on non-block types** (`Int` has no fields) uses `$overload`. Extension is scope-based: `$decl show $overload (show_mine, show)` prepends a candidate in an inner scope.
- **Deriving** a trait from an implementation: `$traitsof` (§4.13).
- **Dynamic dispatch**: a `&const shape` reference accepts any conforming block; see §7.4 for cost.

No trait keyword exists. Traits are blocks, conformance is subtyping, witnesses are blocks.

**Composing traits.** A template that needs several capabilities of one type takes one witness for a combined trait (`hashkey` = `hash` + `eq`) rather than one witness per trait. Since traits are just blocks of props, a combined trait is written by listing the props; there is no second mechanism for trait composition.

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
- A reference's **kind** (§3.5) costs nothing at runtime: frame and allocated references are both thin pointers, and the distinction exists only to be checked.
- **Fat references remain only for trait objects**: a `&const trait` carries the `$impl` witness (§4.12), emitted statically. That table exists because the trait's props are function implementations, not because of layout.

### 7.5 Runtime type information

Values of union type carry a discriminator so `$match` can test them. Blocks differing only in props are distinguished by that discriminator; no other construct reads it.

### 7.6 Memory: two kinds of storage, no collector and no inference

Only `$new` and `$alloc` allocate, and there are no references into value
fields, so storage is the only thing to manage — and which kind of storage a
reference names is in its type (§3.5).

**Frame storage** (`$new`) is released when its scope exits. There is no
allocator, no header, no bookkeeping and no runtime component; the release is a
scope ending. It is safe because §5.3a prevents a frame-bound value from
outliving that scope, which is a structural check on inferred types rather than
an inference of its own. Nothing is annotated and nothing is solved.

**Allocated storage** (`$alloc`) comes from `allocator`, an ordinary name
resolved lexically: the root block declares the default for a target, and
`$decl allocator …` in a block overrides it for everything lexically inside.
An allocator releases when the author says so, which makes `$alloc` **unsafe by
declaration** — the same status as `$extern` (§4.16). A reference used after its
allocator released it is the author's error.

The division is deliberate: the common case is free and safe, and everything
that outlives a scope is written down. There is no garbage collector, no region
inference, no implicit region parameters, and no lifetime syntax — the only
thing the type system carries is which of two kinds a reference has.

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
| Numeric | `add sub mul div mod neg lt` | each `$overload` over `(Int,Int)` and `(Float,Float)`; no implicit conversion; `Int` overflow panics |
| Numeric, explicit | `add_wrap sub_wrap mul_wrap add_sat sub_sat mul_sat` | wrapping / saturating `Int` arithmetic |
| Bitwise | `band bor bxor shl shr` | on `Int` |
| Conversion | `to_float to_int to_str` | `to_int` overloaded: `Str -> option Int`, `Float -> option Int` (`none` if out of range) |
| Equality | `eq` | overloaded over `Int Float Str Bool`; structural equality on blocks is a trait |
| Strings | `concat len slice byte` | **byte** units. `byte (s, i)` reads one byte as `Int`. `len` counts bytes; `slice (s, i, j)` takes byte offsets and panics if an offset splits a code point, preserving the validity invariant. Code-point and grapheme iteration are library; `eq` is bytewise (equal to code-point equality under the invariant) |
| Arrays | `array at alen` | `$call array (n, example)` → `&mut [T]`, contiguous, bounds-checked; `at` → fat `&mut T` (or `&const T` through a `&const` array); length not part of the type |
| Control | `panic` | returns `⊥`; aborts, no catch |
| Shapes | `err none` | patterns for `$try` |
| Bounds | `sendable` | compiler-known template bound (§7.8) |
| FFI | `str_ptr array_ptr box_ptr unbox` | raw addresses for `$extern`: `str_ptr (s)`, `array_ptr (a)`; `box_ptr (r)` takes the address of storage; `unbox (addr, example)` recovers a reference typed by the example. All unsafe by declaration |
| Build | `compiler` | see §9 |

**Platform** — library code over `$extern`, present per target: `print`, `read`, files, sockets, `spawn`/`join`/`channel`/`mutex`/`atomic`, `malloc`-backed allocators. The root block defines `option` and `result` before any of these so failing operations return them; arithmetic (`div` by zero) and `slice` out of range panic.

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
- **Tests are a structural interface**: any block conforming to `{$prop name ""  $prop run $func () true}`. Metadata is props (`$prop tags ("slow", "net")`). The runner is library code.
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
emit    : program      -> { $decl text … $decl diagnostics … }   // the target's source or object text
link    : (emitted, …) -> { $decl path … $decl diagnostics … }
```

Every step that can fail carries its diagnostics beside its result rather than
raising: §4.15 makes an expected failure a value, and a step that stopped still
has to hand the next one something of the right shape. `verify` is the one that
cannot fail, because it *is* the diagnostics. The path travels with the text
because a diagnostic names its own file and `$import` resolves relative to the
entry (§4.14) — the caller is not asked to remember it.

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
13. For the same reason, an `$impl` witness (§4.12) is a static table exactly when its function props are capture-free, which is the ordinary case; a witness whose props capture is an ordinary runtime block.
14. Storage that outlives the scope it was made in must be written `$alloc`, so a container returned to a caller names an allocator (§5.3a) while one used within a scope is free. The cost lands at the container, not at every use.
15. There is no optimisation level and no canonical pass pipeline (§9.2), so `emit` must stay correct on unoptimised input and no pass may be assumed to have run. The cost of "optimisation is a library" is paid by the compiler, not by the user.
16. Frame storage is safe by construction and allocated storage is **unsafe by declaration**: the language guarantees a frame reference never dangles, and says nothing about an allocated one after its allocator released it. There is no collector and nothing is inferred.

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

**Trait, implementation, witness**

```
$decl rect { $decl w $new 0.0  $decl h $new 0.0 }
$decl rect_shape $impl rect shape {
  $prop area $func ($decl r $const $new rect) $call mul (r.w, r.h)
}
$call rect_shape.describe (rect)     // "area=0"
```

**Deriving a trait from an implementation**

```
$decl point { $decl x $new 0.0  $decl y $new 0.0
  $prop len $func ($decl p $const $new point)
    $call sqrt ($call add ($call mul (p.x, p.x), $call mul (p.y, p.y))) }

$decl vec3 $impl { $decl x $new 0.0  $decl y $new 0.0  $decl z $new 0.0 }
               ($traitsof point)
               { $prop len $func ($decl v $const $new vec3) … }
```
