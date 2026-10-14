// A module member that specialises itself. A member template is reached through
// the module's props rather than the entry file's globals, so it takes a different
// lowering path from `selfspec.mpl`'s own.
$decl pair $template T {
  $prop mk $func ($decl a T, $decl b T) { $decl fst a  $decl snd b }
  $prop swap $func ($decl p $call mk (T, T)) $call ($specialize pair T).mk (p.snd, p.fst)
}
