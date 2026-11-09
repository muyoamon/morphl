# Owned text: design note

Status: **decided; steps 1–3 are in** — SPEC (§2.1, §2.2, §3.1, §5.3a, §7.6, §8, §11) and
BOOTSTRAP (§1, §2) say what is decided, SPEC §11 says it is being implemented, both stages
have `$primitives`, which the compiler builds its text through, and `$alloc` of a
constructing call allocates the block. The plan is at the end. STRINGS.md made text cheap to build
(one `concat_all`, O(L)); this note is about who owns the bytes and when they are released.

| | question | decided |
|---|---|---|
| T1 | what a `Str` is | a **non-owning view**: static bytes, a slice, or bytes lent by an owner |
| T2 | where allocating string operations go | behind a new keyword, **`$primitives`**, for the compiler alone |
| T3 | who owns bytes | `std/str`'s **text**, one type that is both builder and string |
| T4 | a text's lifetime | a **constructor**: frame by default, `$alloc` of the call for the heap |
| T5 | what a view of a text is | a value holding a **reference** to the text, so §5.3a confines it |
| T6 | mutation while a view exists | text is **append-only**; other changes bump a **generation** that views check |
| T7 | bytes | a **byte type**, `$primitives.u8`, written through `unbox` |

## The problem

SPEC §7.6 opens: "Only `$new` and `$alloc` allocate, and there are no references into value
fields, so storage is the only thing to manage." That is false today. `concat`, `concat_all`,
`int_to_str`, the `to_str` overloads, `from_code`, `read_file` and `str_from_ptr` each make a
new run of bytes, through `mpl_alloc` (a `malloc`), and nothing ever frees them. A `Str` is a
value, not storage, so `$free` cannot take one, and no allocator ever sees one. The bytes
have no owner and no lifetime in the spec: every string a program builds lives until it
exits.

For the compiler that is tolerable: it runs once, and STORAGE.md §C found its garbage
interleaved with what it keeps, so phase arenas would reclaim little. For anything that runs
long it is not. The language server already works around it by checking each document in a
child process.

STRINGS.md fixed the *cost* of building text and left the *ownership* where it was. Its
S3, no byte buffer, is right at the language level and still holds: nothing here adds a new
kind of runtime value. What changes is that the buffer becomes **library**, owned by
`std/str` and made from storage the language already accounts for.

## T1. `Str` is a view

A `Str` stays what §3.1 says: two words, pointer and length, valid UTF-8, immutable to its
reader. What it no longer does is own anything. Its bytes are one of three things:

- **a literal**, static, living as long as the program;
- **a slice of another view**, the same bytes;
- **bytes an owner lends**, valid while the owner lives (T5).

The operations that only read stay in the root block: `len`, `slice`, `byte`, `eq`, and the
platform's `print`, `eprint` and `write_file`. None of them allocates.

## T2. `$primitives`

The operations that allocate move behind a keyword: **`$primitives`**, arity 0, valid only as
the target of a projection (`$primitives.concat`) and as the initializer of a whole-member
alias (`$decl concat $primitives.concat`). Evaluating it alone is an error: a value of the
whole set is a large record nothing needs.

| moves to `$primitives` | replaced for programs by |
|---|---|
| `concat`, `concat_all` | `std/str`'s text |
| `int_to_str`, `to_str` | `std/fmt`, writing digits into a text as slices of `"0123456789"` |
| `from_code` | `std/str`, encoding the code point into bytes |
| `read_file` | `std/io`, reading through `$extern` into a text (it already declares `read` and `memmove`) |
| `str_from_ptr` | `std/str`, copying into a text |

**Why a keyword.** §2.1 forbids an identifier starting with `$`, so `$primitives` can never be
shadowed: `$primitives.concat` means the primitive in every file, and a library's own `concat`
can never be mistaken for it. Every use is visible to `grep`. A built-in module
(`$import "core:prim"`) was the alternative; it needs a loader that serves a virtual file, and
its members can be shadowed once bound.

**Who uses it.** The compiler, through its prelude, and `std/`. It runs under stage 0, which
cannot run `std/` (BOOTSTRAP §1.2 refuses FFI, and `std/` is compiled-only, STDLIB D8), so
it keeps building text the way it does now, `P.join_chunks` over `$primitives.concat_all`, and
keeps not freeing it. That leak is a property of the bootstrap, not of the language. Nothing
stops a user writing `$primitives`; the `$` says it is outside the language, and a lint can
say so later, once there are suppressible warnings.

**What it gains.** The byte type (T7), and one new primitive, `$primitives.view (addr, n)`: the bytes at `addr` as a
`Str`, **unchecked** — no copy and no UTF-8 validation. It is sound only in `std/str`, which
writes nothing but bytes copied from views and code points it encoded itself, so what it
views is valid by construction. The whole FFI group moves here too — `str_ptr`,
`str_from_ptr`, `array_ptr`, `box_ptr`, `unbox`, `raw_alloc`, `raw_free` — so the unsafe set
is behind one keyword; `unbox` is the one door from an address to a reference (T7).

## T3. One type: text

`std/str`'s **text** is a growable buffer, and it is the builder and the string at once:

```
$decl t $call S.text ()
$call t.write ("hello, ")
$call t.write (name)
$call I.print_line ($call t.view ())
```

A text holds an address from `allocator.alloc`, a capacity, a length and a generation
(T6). Writing copies the bytes in at once, growing the buffer by doubling.

**This reverses STRINGS.md's choice for the library**, and the reason is ownership. STRINGS.md
S3 preferred a list of pieces joined once, which copies L bytes, over a doubling buffer,
which copies about 2L–3L. That was right while every `Str` lived forever. A piece is now a
borrowed view, and a list of them joined later reads freed memory if any piece's owner went
first. Copying at `write` is the only design whose correctness does not depend on the caller
keeping every piece alive, and the difference is a constant factor, not the O(L log n)
STRINGS.md removed. The compiler keeps the pieces design, since its strings never die.

**Its bytes are valid UTF-8 by construction.** It is written with views, which are valid, and
with code points it encodes itself. Any operation that cuts it (`truncate (n)`) panics when
`n` would split a code point, as `slice` does.

## T4. A text's lifetime: a constructor, or `$alloc` of one

`S.text` is a **constructor** (§5.3a): its body is a `$new`, so its caller provides the
storage.

```
$decl text $func () $new {
  $decl addr $mut $alloc ($call allocator.alloc (16))
  …
  $defer $call allocator.free ($call C.ival (addr))
}
```

- **Frame text is the default.** `$decl t $call S.text ()` puts the text in this scope's
  frame. `t` owns it, and its deferral frees the buffer when the scope ends. §5.3a's rules
  confine it already: it cannot be returned unless the caller constructs too, cannot be
  stored (A0), and cannot be passed in a tail call (A4). So a frame text can neither leak nor
  outlive its scope, and both are checked at compile time.
- **Heap text is `$alloc` of the call.** `$decl h $alloc $call S.text ()` allocates the
  constructed block instead, and its deferral becomes the allocator's: run by `$free h`, or
  when the arena that made it is released (§7.6, "an `$alloc` block's deferrals are the
  allocator's to run"). It can be stored and returned, and releasing it is the author's
  responsibility, as for any `&^T`.

**`$alloc` of a constructing call is new**, and it is `$alloc $new …`, since a constructing
call is "frame storage of the scope it stands in, exactly as if that `$new` were written at
the call". Three things make it sound and cheap:

- **It replaces a reading that was a trap.** Before, `$alloc` of a constructing call read
  the place through as a value (A0): the block was built in the frame and copied. Stage 0
  then ran its deferrals when the frame ended, while the copy lived on — releasing what the
  storage still held — and the compiled program already ran them at `$free`, so the two
  stages disagreed on the same program. Now both mean the allocated block, and stage 0,
  which releases nothing, refuses one with deferrals, as it refuses `$alloc { … $defer … }`.
- **The deferral rule already fits.** §4.15a lets a constructed block's deferrals name only
  the block's own bindings, the file's top level and the root block. That is what a deferral
  needs when it runs at `$free` or at an arena's release, outside every frame.
- **The machinery exists.** Lowering returns a constructed block by value and the caller
  wraps it (`ctor_site`). Wrapping it in an `$alloc` node, and handing `drop` to the allocator
  as a finaliser rather than to the frame, is what `$alloc { … $defer … }` already does
  (DEFER.md, step 4).

`$mut $alloc $call S.text ()` works the same way. A fallible constructor answers `<&T, none>`,
so `$alloc` of one answers `<&^T, none>`.

**A text drawing from another allocator keeps it in a field**, and frees through the field,
since the deferral may not name the constructor's parameters. The allocator is a parameter of
`S.text`, defaulted to the root's, and it is named **`ator`**: a parameter named `allocator`
defaulted to `allocator` would read the slot it initialises, so the body binds
`$decl allocator ator` instead.

**A function that hands back text constructs.** Its body is the `$new`, a tail call to a
constructor, or an `$if`/`$match` whose arms are such calls. Because a call inside a block is
never in tail position, a helper cannot compute in a block and then return a text. Two idioms
cover it:

- **Write into a text the caller owns.** This is what `std/fmt` already does: every writer
  takes a builder first and answers unit. The caller constructs; helpers borrow and write.
- **Compute in the arguments of a tail-called constructor**:
  `$func (n) $call S.concat (S.digits (n), "!")`.

## T5. A view is a reference

`t.view ()`, and every slice of one, answers a **view**:

```
{ $decl of <&const text>  $decl at 0  $decl n 0  $decl gen 0 }
```

The owner, an offset, a length, and the generation it was made under (T6). It holds a
reference, so §5.3a confines it without new machinery:

- `view` returns its receiver, a borrowed place, which R2 allows. At the caller the result
  holds the caller's own place, so a view of a frame text cannot be returned, stored or
  passed in a tail call. To return it, **promote** it: copy it into a heap text, or construct.
- A view of a heap text holds an `&^const` reference, which is not frame-bound, so it can be
  stored and returned. From there it is the author's responsibility, as the text is.
- `$const` stops writing through the view.

`std/str` provides the operations on views: `len`, `byte`, `eq`, `slice`, `find`,
`starts_with`, `split` and the rest. Each reads through the owner's current buffer.

**The guard is only as deep as the API.** A view read out as a plain `Str` is an ordinary value
§5.3a does not track. So users never hold a raw `Str` of a text. Extraction is one function,
`S.raw_str (v)`, valid until the text next grows or its owner ends, and it is called only for the
length of a platform call: `std/io`'s `print_line` and `write` take a view and extract it
inside.
Literals stay plain `Str`, which is fine, since they are static.

## T6. Mutation under a view: append-only, with a generation

Two different bugs hide here: a view's **content changing** (a view of `"abc"` reading `"abd"`
later, breaking what §3.1 promises a reader), and its **bytes moving** (the buffer reallocated,
and the old address read).

**Text only grows.** Appending never changes bytes already written, so a view's bytes never
change. A view holds an offset, not an address, so a reallocation does not touch it: each read
goes through the owner's current buffer. As long as the owner lives, a view is stable, and a
frame owner's life is checked (T4).

**Anything else bumps the generation.** `clear` (to reuse the buffer) and `truncate` add one to
the text's generation. A view recorded the generation it was made under, and reading it panics
when the two differ.

**Why not a reference count with a panic on mutation.** It was weighed and lost on two counts
specific to morphl:

- **It cannot be sound.** A count is released by a deferral when the view dies, so a view
  would be a constructed object. §5.4 reads a reference as its pointee wherever a value is
  expected, so a view's block can be copied out as a plain value, uncounted and with no
  deferral. Once the original's scope ends the count is zero while the copy is still readable.
  morphl cannot forbid copying a value.
- **It panics on correct code.** The count drops at the end of the view's scope, not after its
  last use, so `$decl v (view)`, a use of `v`, then `$call t.write ("x")` panics with `v` never
  read again. That is the shape Rust needed non-lexical lifetimes for, here as a run-time
  failure. It also forbids `t.write (t.view ())`.

| | reference count | append-only + generation |
|---|---|---|
| sound against copies | no | **yes**: a copy carries its generation |
| view dropped, then mutation | panics until the view's scope ends | **fine** |
| stale view read after `clear` | caught, at the mutation | caught, at the read |
| `t.write (t.view ())` | panics | **works**, if `write` reads its source after growing |
| cost per view | a constructed object and two count updates | four words |
| cost per read | none | one comparison |

The count's advantage, general mutation, is kept: `clear` and `truncate` exist and are safe.
They invalidate the views outstanding, loudly, at their next read.

**The hazard left** is a raw `Str` extracted before a growth, which is why extraction is
confined to platform calls (T5).

## T7. Bytes

A byte type exists: one byte of storage. There is no syntax for a type, so it is reached
through an example value, **`$primitives.u8`** — behind the keyword, since its uses are byte
storage and C `char` buffers, both unsafe already, and the root's `byte (s, i)` already
answers an `Int`. Two conversions go with it: `$primitives.to_u8 (n)`, which **panics** when
`n` is outside 0..255, as checked `Int` arithmetic does (truncating is spelled
`band (n, 255)`), and `$primitives.of_u8 (b)`, its `Int`.

`std/str` writes bytes through `unbox`, which answers an `&^mut` reference of the example's
type at an address:

```
$set ($call $primitives.unbox ($call add (addr, i), $primitives.u8))
     ($call $primitives.to_u8 (c))
```

Bulk copies, a view into the buffer, go through `$extern "memcpy"` with `$primitives.str_ptr`, since a byte
loop in morphl is slow for large text and `std/` is compiled-only, so `$extern` is available.

**Reinterpretation was considered and dropped.** A `$as A B` keyword (B's bits read as A) would
have covered byte writes and the unchecked view; `unbox` and `$primitives.view` cover both
without a new form, and widening types belongs to a different design.

## Spec changes

- **§2.2**: `$primitives`, arity 0, a projection target or a whole-member alias only.
- **§3.1**: a `Str` is a non-owning view of valid UTF-8 bytes (static, a slice, or lent by
  storage). A view used after its storage is released is the author's error, as `&^T` is.
- **§5.3a**: `$alloc` of a constructing call allocates the constructed block; its deferrals
  are the allocator's.
- **§7.6**: "only `$new` and `$alloc` allocate" holds for every program; `$primitives` is the
  stated exception, and its bytes are never released.
- **§8**: the table splits into views (root), `$primitives` (the allocating and unsafe names),
  and what library modules own. The byte type and its conversions are added.
- **BOOTSTRAP §1**: the compiler's subset reaches the allocating operations through
  `$primitives`, via the prelude. **§2**'s table moves with §8's.

## Settled in step 1

- **The byte type** is `$primitives.u8`, with `to_u8` and `of_u8` (T7).
- **An `Int` outside 0..255** converted to a byte panics (T7).
- **The allocator parameter** of `S.text` is `ator` (T4).
- **`str_ptr` and `array_ptr`** move to `$primitives` with the rest of the FFI group (T2).

## Open

1. **Arrays.** `array (n, x)` and `args` allocate outside `$new`/`$alloc` too, so the same
   principle applies: an array becomes a view and owning sequences live in `std/vec`. It is a
   separate, larger step, since an array is `concat_all`'s argument and `run`'s. SPEC §11 says
   so.
2. **A lint for `$primitives` outside `std/` and the compiler**, which waits on suppressible
   warnings.

## Plan

1. **This note**, and the SPEC and BOOTSTRAP text. Done.
2. **`$primitives`.** Done, for the six members that build strings (`concat`, `concat_all`,
   `to_str`, `int_to_str`, `from_code`, `read_file`); the FFI group, the byte type and `view`
   join in step 4. Each stage keeps the member list (`builtins.primitives`, `infer.mpl`'s
   `prim_members`) and a Zig test checks they agree. A member resolves in the root itself —
   stage 0's root scope, inference's `root_env`, lowering's `st.rootenv` — so a file's own
   `concat`, even one calling the member, does not stand in for it, and it lowers to the
   `prim` node a root name does: the compiler's C still calls `mpl_concat` directly at every
   site. `$primitives` alone and a non-member are refused in both stages. Each compiler
   module aliases what it calls after its imports (`$decl concat $primitives.concat`), which
   left its ~1,590 call sites as they were and cost the emitted compiler one thunk per alias
   (5,383,402 → 5,397,774 bytes). Two regenerations: the keyword first, then its uses.
   `primitives.mpl` and the `test-reject` case `primitives_bad.mpl` are the fixtures.
3. **`$alloc` of a constructing call.** Done. Lowering already handed the built block's
   `drop` to the allocator (`alloc_fin`), but it built the block in the frame and allocated
   a copy; now `ctor_site` allocates it once, from the allocator at the `$alloc` (`ctalloc`),
   and registers the `drop` with its `defer_at` inside the built arm. Inference types a
   fallible one `<&^T, none>` (`T.to_alloc`, shared), where it said `&^<T, none>`, and
   `$free`'s routing follows a `$try` to its operand and counts such a result as allocated
   (`T.alloc_res`) — without both, the block could be built and never named to be freed.
   Stage 0 refuses one with deferrals, as it refuses `$alloc { … $defer … }`; it used to run
   them when the frame ended, while the compiled program ran them at `$free`. Fixtures:
   `ctor_alloc.mpl` (frame and heap from one constructor, `$free`, never freed, `$mut`,
   fallible built and not; compiled only) and `std/mem_test.mpl`'s arena case (13).
4. **The byte type**, `$primitives.view`, and the FFI group's move.
5. **`std/str`'s text and views**, with `std/fmt` and `std/io` moved onto them, and
   `std/str_test.mpl` covering growth, a view across growth, `t.write (t.view ())`, a stale view
   after `clear` panicking, `truncate` at a code-point boundary, and a heap text freed by an
   arena. Run under ASan, which is what catches a view read after its owner.
6. **The root's allocating names removed.** Stage 0's `builtins.zig`, `infer.mpl`'s `root_env`,
   `emit.mpl`, the Zig test that the two root blocks name the same things, and every fixture
   and `std/` module that still calls them.
7. **Arrays**, by the same principle, separately.
