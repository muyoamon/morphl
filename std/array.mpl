$alias Iterable $member $import "iterable.mpl" Iterable;

$decl Array $template (T, L) $impl $specialize Iterable T {
  
  $decl val $array T L;
  $decl length $add L 0;

  $prop get $overload 
    $func ($decl idx 0) {
      $ret $index $member $parent val idx;
    }
    $func () {
      $ret $member $parent val;
    }
    ;

  $prop set $func ($decl idx 0, $decl val T) {
    $set $index $member $parent val idx val; 
  };
  
} {
  $prop foreach $func ($decl cb $func T ()) {
    $decl i $mut 0;
    $decl this $ref $parent;
    $while $lt i $member this length {
      $call cb $call $member this $get i;
      $set i $add i 1;
    }
    $ret ();
  };
};

