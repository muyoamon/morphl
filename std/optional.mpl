$alias Bool $size 1 0;

$decl Optional $template T {
  $decl val $union
    $null
    T 
  ;

  $prop has_value $func () $eq ($member $member $this val $$tag) 0;

  "Return value as T, UB if val is null"
  $prop value $func () $as $member $this val T;


  $prop value_or $func ($decl default T) {
    $if ($call $member $parent $has_value ()) {
      $ret $call $member $parent value ();
    } {
      $ret default;
    }
  };
};
