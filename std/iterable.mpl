$alias callback $overload
  $template (T,R) $func T R
  $template T     $func T ()
  ;

$alias Bool $size 1 0;

$alias Optional $member $import "optional.mpl" Optional;

$decl Iterator $template T $traits {
  $prop valid $func () Bool;

  $prop get $func () $specialize Optional T;

  $prop next $func () ();
}

$decl Iterable $template T $traits {
  $prop foreach $func ($decl cb $func T ()) ();
};
