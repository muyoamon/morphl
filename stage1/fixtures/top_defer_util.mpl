// DEFER.md example 12, a module's half: initialised before its importer, so its top-level
// deferrals run after the importer's — registered where initialisation reaches them.
$defer $call print ("u1\n")
$decl res $new { $decl k 2  $defer $call print ("u2 ") }
$decl val $call add (res.k, 1)
