// §5.1's block rule is depth as well as prefix: a field is coerced into the target's
// field, not assigned. Each digit is one shape the backend used to emit as a plain
// field copy between two C structs, which `cc` refused.
$decl a  { $prop tag "a" }
$decl b  { $prop tag "b"  $decl x 0 }
$decl u  $union (a, b)
$decl val $func ($decl t u) $match t ($case {$prop tag "b"} t.x, $case t 0)

// An `$if` joining two records whose first fields differ by depth.
$decl pick $func ($decl k 0, $decl w u) {
  $decl r   $if ($call eq (k, 0)) { $decl ty a  $decl m 1 } { $decl ty w  $decl m 2 }
  $decl ret $call add ($call val (r.ty), r.m)
}.ret

// The same one level down: the field is itself a record needing the coercion.
$decl deep $func ($decl k 0, $decl w u) {
  $decl r   $if ($call eq (k, 0))
                { $decl in { $decl ty a  $decl z 3 }  $decl m 1 }
                { $decl in { $decl ty w  $decl z 4 }  $decl m 2 }
  $decl ret $call add ($call val (r.in.ty), $call add (r.in.z, r.m))
}.ret

// Prefix and depth at once: a longer record whose first field is a member, passed where
// the shorter record holding the union is expected.
$decl proto { $decl ty u  $decl m 0 }
$decl take $func ($decl r proto) $call add ($call val (r.ty), r.m)
$decl wide $func ($decl n 0) $call take ({ $decl ty b  $decl m n  $decl junk 9 })

$decl main $func () {
  $decl d1  $call add ($call pick (0, a), $call pick (1, { $prop tag "b"  $decl x 5 }))
  $decl d2  $call add ($call deep (0, a), $call deep (1, { $prop tag "b"  $decl x 1 }))
  $decl d3  $call add ($call take ({ $decl ty a  $decl m 4 }), $call wide (2))
  $decl ret $call add ($call mul (d1, 100), $call add ($call mul (d2, 10), d3))
}.ret
