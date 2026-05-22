# morphl Language Specification

> **3rd Revision**

> **Status**: Draft — design is active and evolving. Sections marked ⚠️ are unsettled.
---

## 1. Design Philosophy

morphl is a statically typed, structurally typed language designed around the following core principles:

**Unified Semantics** - morphl has minimal core construct and syntax. Compound construct should compose from core construct with no edge cases. Every construct should have same semantics no matter where they placed.

**Verbatim execution** — program flow maps directly to written code. There are no implicit allocations, implicit copies, implicit conversions, or hidden control flow. Every runtime action corresponds to something the programmer explicitly wrote.

**Everything is an expression** - morphl has no statements. Every construct produces a value. Control flow, declarations, blocks, and functions calls are expressions terminated by `$$end` or `;`. The distinction between statement and expression does not exist.

**No namespace pollution** — all language keywords are prefixed with `$`, reserving the unprefixed namespace entirely for user-defined identifiers.

**Explicit storage** — mutability, indirection, and ownership are expressed through storage expressions, not through separate annotation syntax.

---

## 2. Keyword Namespace

Every language keyword is prefixed with `$`. This ensures language constructs never conflict with user-defined field names.

### 2.1 Single-`$` Keywords 
Reserved keywords include: `$decl`, `$prop`, `$mut`, `$const`, `$ref`, `$new`, `$func`, `$ret`, `$call`, `$impl`, `$traits`, `$import`, `$extern`, `$set`, `$null`, `$this`, `$parent`, `$file`, `$global`, `$exit`, `$defer`, `$if`, `$while`, `$break`, `$continue`, `$and`, `$or`, `$not`, `$union`, `$array`, `$never`, `$as`, `$overload`, `$template`, `$specialize`, `$static`, `$inline`, `$heap`, `$free`, `$group`, `$block`, `$syntax`, `$size`, `$align`, `$signed`, `$unsigned`, `$udiv`, `$umod`, `$ult`, `$ugt`, `$ulte`, `$ugte`, `$ushr`, `$i2f`, `$f2i`, `$idtstr`, `$strtid`, `$forward`, `$band`, `$bor`, `$bxor`, `$bnot`, `$lshift`, `$rshift`, `$req`, `$rneq`, `$rem`, `$fadd`, `$fsub`, `$fmul`, `$fdiv`.

### 2.2 Double-`$$` Directives
`$$`-prefixed name are compiler directives - They are as-early-as-possible resolutions. The compiler substitute them at compile time whenever it can determine the value statically. If it cannot, resolution defers to runtime

Reserved directives: `$$syntax`, `$$spread`, `$$maybe`, `$$op`, `$$type`, `$$size`, `$$name`, `$$path`, `$$delim`, `$$version`, `$$line`, `$$col`, `$$tag`, `$$data`


