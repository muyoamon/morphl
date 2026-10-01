// The third half of `test-stable`, and the one that guards **load order**. The
// prelude is reached through `stable_util` first and named directly second, so every
// counter in lowering — module ids, ranks, opaque ids, the emitter's temporaries — is
// at a different value by the time the prelude's members are lowered than it is in
// `stable_a`, where the prelude is the first thing loaded.
//
// `prelude.c` must come out byte-identical to `stable_a`'s all the same, and it does
// only because none of those names is drawn from a counter any more. The same member
// set has to be projected in both, since a module's *contents* are a whole-program
// fact (§4.9) even once its *naming* is not — hence `P.not` and nothing else.
$decl U $import "stable_util"
$decl P $import "../prelude"
$decl main $func () $if ($call U.f ($call P.not (true))) 7 0
