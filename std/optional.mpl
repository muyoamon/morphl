$decl Optional $template T {
  $decl tag $mut 0;
  $decl data $mut ($as 0 T);

  $prop has_value $func ($decl this $implicit $ref $this) $member this tag;

  $prop value $func ($decl this $implicit $ref $this) $member this data;

  $prop value_or $func ($decl this $implicit $ref $this, $decl default T) {
    $if $member this tag {
      $ret $member this data;
    } {
      $ret default;
    }
  };

};
