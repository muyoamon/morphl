// The module under test. Its interface carries a `cv_opaque` (a `$func`-valued prop)
// and a `t_tmpl` (a template), which are the two identities inference mints — so its
// serialised interface is exactly what must not depend on the importing program.
$decl P $import "../prelude"
$prop mk $func ($decl v 0) { $decl val v }
$decl pair $template T { $prop of $func ($decl a T) { $decl v a } }
$decl two $func () 2
