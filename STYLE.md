# Formatting morphl source

SPEC §2.1: "Newlines are whitespace. The language does not dictate formatting." This file is the
codebase's convention for `.mpl` source — `stage1/` and its fixtures — not a rule of the language.
Where it is silent, match the surrounding code.

## Whitespace

- Spaces only, never tabs. No trailing whitespace. One blank line between top-level items; a
  comment sits directly above what it describes, with no blank line between them.
- **100 columns** for code and comments. A string literal may run past it when splitting it would
  only add `concat`s (`emit.mpl`'s C runtime is the case).
- No `;`. §2.1 permits it between expressions and gives it no meaning.
- A space before every argument list and parameter list: `$call f (x, y)`, `$func ($decl x 0)`.
  The one exception is a callee that is itself parenthesised: `$call ($call mk ()).f (1)`.

## Indentation

- **Two spaces** per level of nesting: a top-level item's body, a block's items, `$match`'s arms.
- **A wrapped line continues at +4** from the line it continues, whatever the callee's name:

  ```
  $decl r $call blk_acc (
      $call IR.bslots.cons ($call IR.bslot (sl, ir), $call IR.bslots.val (a.slots)),
      $call T.props.val (a.prps))
  ```

- A parameter list that does not fit wraps at +4 as well.

## Blocks

A block that fits on one line stays on one line, items separated by two spaces:

```
$decl fnm_ent $func ($decl k "", $decl i 0) { $decl key k  $decl idx i }
```

Otherwise **`{` ends the line that opens it**, the items start on the next line indented two
spaces, and the closing brace — with its projection — has a line of its own at the indentation of
the line that opened the block:

```
$decl lower_item $func ($decl st proto_lst, $decl it Pa.proto_node) {
  $decl nm  $call name_of ($call op (it, 0))
  $decl v   $call lval ($call lower (st, a.env, $call op (it, 1), false))
  $decl ret $call blk_acc (nm, v)
}.ret
```

The same holds where a block is an operand. What follows the block continues on its closing
line:

```
$if ($call is_form (it, "decl")) {
  $decl nm $call name_of ($call op (it, 0))
  $decl ret $call lower_decl (st, nm, it)
}.ret ($call lower_other (st, it))
```

### The return idiom

A block returns a value as `{ … $decl ret e }.ret` (SPEC §3.3 writes it with `r`; the codebase
uses `ret`). **The field is always `ret`.** A block nested inside one that already binds `ret` uses
`ret2`, the next `ret3`, and so on. Reusing `ret` there would be legal — §4.1 allows shadowing an
enclosing binding — but two `ret`s would be in view at once, and a reader would have to count
braces to know which `.ret` is which. `ret` is never an ordinary name, so the field cannot collide
with a local the block also needs, which a one-letter name like `r` regularly did.

### Alignment

Within one block, consecutive `$decl`s are **aligned**: names padded so the initializers start in
one column. Alignment never reaches across blocks, and a `$decl` whose name is much longer than
its neighbours' may break the column rather than pushing every other line right.

```
$decl sl  $call fresh_slot (st, id)
$decl ir  $call with_pending (a.pend, v.ir, id)
$decl ret $call blk_acc (sl, ir)
```

## Forms

- **`$match`** puts its arms on the following lines, two spaces in, one `$case` per line where it
  fits. A top-level `$match` closes with `)` alone in column 0; a nested one closes on its last
  arm's line.

  ```
  $decl is_nil $func ($decl xs node) $match xs (
    $case {$prop tag "cons"} false,
    $case xs true
  )
  ```

- **`$if` chains**: prefer a table lookup or a `$match` where one fits. Nested `$if`s end in
  stacked closers, and those must be counted, not guessed.
- **Function headers** keep every parameter on the header line when it fits; otherwise the list
  wraps at +4.

## Comments

- `//` only. `/* */` is legal (§2.1) and unused.
- A file opens with a header comment saying what the module is and what it deliberately is not.
- A section divider is `// ` followed by dashes and the section name, ending at column 80:

  ```
  // ---------------------------------------------------------------- characters
  ```

- A comment explains *why*. A section number (`§4.10`) names the rule a line implements, so a
  reader can check it against SPEC.md.
