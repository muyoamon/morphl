// §4.14's search roots: `mplc libroot.mpl -L stage1/fixtures/lib`. A name resolves
// beside the entry file first and then in each root in order (`Pa.resolve_import`).
//
// 10 + 12 + 1 = 23: a library module, a library module importing another through the
// root, and a module beside the entry winning over the root's of the same name (100).
$decl W    $import "std/lr_twice"
$decl B    $import "std/lr_both"
$decl K    $import "lr_pick"
$decl main $func () $call add ($call add ($call W.twice (5), $call B.four (3)), K.which)
