// A module whose members form a *cycle* through §4.11's `$fwd`, where the one
// reached first does not name itself.
//
// This is `types.mpl`'s `show` / `show_fields` in miniature, and it is the
// shape that broke the backend: lowering a module derives its members' types
// rather than reading inference's answers, so while `shw` is being lowered its
// own result is not known and a call to it types as §5.5's placeholder. A node
// keeps its type as an interned *index*, so the nodes `shw_fields` built across
// that call could not be revised — and `shw_fields` was only ever re-lowered
// when it named *itself*, which is not what a group does.
$fwd shw

$decl shw_fields $func ($decl n 0, $decl acc "")
  $if ($call lt (n, 1)) acc
      ($call shw_fields ($call sub (n, 1),
           $call concat (acc, $call shw ($call sub (n, 1)))))

$decl shw $func ($decl n 0)
  $if ($call lt (n, 1)) "y" ($call shw_fields ($call sub (n, 1), "x"))
