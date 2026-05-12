$alias Iterable $member $import "iterable.mpl" Iterable;
$alias Optional $member $import "optional.mpl" Optional;
$alias Bool $size 1 0;

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

  $prop iter $func () {
    $decl this $ref $parent;
    $ret $new $inline {
      $decl val $array T L;
      $decl length $add L 0;
      $decl idx $mut 0;

      $prop valid $func () $as ($lt ($member $this idx) ($member $this length)) Bool;

      $prop get $func () {
        $ret $new ($specialize Optional T);
      };

      $prop next $func () {
        $set ($member $parent idx) ($add ($as $member $parent idx 0) 1);
        $ret ();
      };
    } (($member this val), ($member this length), 0);
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
