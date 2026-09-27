// A regression test for §4.14 and §4.10 meeting in `mpl_init`. Prints 106.
//
// `v` is a top-level `$decl` in the *entry* file whose initializer calls into an
// imported module, and that module has a member which is a static rather than a
// function. §4.10 initialises a `$decl` once in source order and `$import`
// evaluates the module's block where it stands, so `base` must be assigned
// before `v` is.
//
// The backend assigns statics in index order, and the entry file's own globals
// used to be numbered *before* every lifted function — so `base` was assigned
// after `v` had already read it. With the bug this prints 101 rather than 106,
// and in a real driver, where the uninitialised static is a module value that
// something dereferences, it segfaults instead.
$decl U $import "init_util"

$decl v $call U.bump (1)

$decl main $func () $call add (v, 100)
