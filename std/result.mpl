$alias Bool $size 1 0;

$decl Result $template (T,E) {
  $decl val $union
    T 
    E 
  ;

  $prop is_ok $func () $eq ($member $member $this val $$tag) 0;

  $prop is_err $func () $eq ($member $member $this val $$tag) 1; 

  $prop ok $func () $as $member $this val T;

  $prop err $func () $as $member $this val E;
};
