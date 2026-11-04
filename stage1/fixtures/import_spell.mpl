// §4.14: "all imports of the same resolved file yield the same module", however the path is
// spelt. The entry names `./import_spell_inner` and its module names the same file through
// `../fixtures/`, so the resolved path is normalised as text (`Pa.join_path`); keyed as
// written they were two modules — the inner effect ran twice ("i i 5") and two outputs
// defined its functions, which `cc` refused.
$decl M $import "import_spell_util"
$decl N $import "./import_spell_inner"
$decl main $func () $call add (M.v, N.w)
