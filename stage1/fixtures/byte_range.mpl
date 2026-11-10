// §8's `$primitives.to_u8` panics outside 0..255, as checked `Int` arithmetic does
// (TEXT.md T7). Compiled only: stage 0 has no byte type (BOOTSTRAP 1.2).
$decl main $func () $call $primitives.of_u8 ($call $primitives.to_u8 (256))
