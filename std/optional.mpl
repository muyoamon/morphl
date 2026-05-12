$alias Bool $size 1 0;

$decl Optional $template T {
  $decl val $union
    $null
    T 
  ;

  $prop has_value $func () $eq ($member $member $this val $$tag) 1;

  "Return value as T, UB if val is null"
  $prop value $func () $as $member $this val T;


  $prop value_or $func ($decl default T) {
    $decl this $ref $parent;
    $if ($eq ($member $member this val $$tag) 1) {
      $ret $as $member this val T;
    } {
      $ret default;
    }
  };
};
