// The same module, reached after one that has already minted a template id and
// several opaque ids. `M`'s interface must come out byte-identical to `iface_c`'s.
$decl X $import "ifx"
$decl M $import "ifm"
$decl main $func () $call add ($call M.two (), $call X.one ())
