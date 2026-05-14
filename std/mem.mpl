"std/mem.mpl - Memory Allocation Library";
"Byte type";
$decl Byte $size 1 $unsigned 0;


"RawBuffer Type";
$decl RawBuffer {
  "byte-addressable raw pointer";
  $decl ptr $mut $ref Byte;
  "Initialized byte length";
  $decl len $mut 0;
  "Allocated byte capacity";
  $decl cap $mut 0;
  "Required alignment in bytes";
  $decl align $const 0;
  "Whether free should release it";
  $decl owned $mut 1;
  "1 on success, 0 on failure/invalid buffer";
  $decl ok $mut 1;
}

"RawSlice Type";
$decl RawSlice {
  $decl ptr $ref Byte;
  $decl len 0;
}

"Native Untyped Memory Allocation";
$decl _c_malloc  $extern "_native_malloc"  $func ($decl size 0) $ref Byte;
$decl _c_realloc $extern "_native_realloc" $func ($decl ptr $ref Byte, $decl size 0) $ref Byte;
$decl _c_free    $extern "_native_free"    $func ($decl ptr $ref Byte) ();


"Morphl Wrapper";

$decl alloc_bytes $func ($decl size 0, $decl align 0) {
  "TODO: should return RawBuffer";
}

$decl realloc_bytes $func ($decl buf $ref RawBuffer, $decl new_size 0) {
  "TODO: should return RawBuffer";
}

$decl free $func ($decl buf $ref RawBuffer) {
  $if $and ($member buf ok) ($member buf owned) {
    $call _c_free ($member buf ptr);
    $set $member buf ptr ($as $null $ref Byte);
    $set $member buf len 0;
    $set $member buf cap 0;
    $set $member buf owned 0;
    $set $member buf ok 0;
  };
  $ret ();
}
