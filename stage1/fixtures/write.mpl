// §8's `write_file`, which had no C backend at all. Prints 161.
//
// It answers `<unit, err>`, and **both members are nullary** — so `opt_slot`, which
// tells `some` from `none` by which one has a field, cannot separate them. They are
// told apart structurally: one *is* the unit type, the other is §4.15's `err` tag
// block. Which *position* each takes still belongs to the call site's interned union
// rather than to the intrinsic, because §3.6 makes a union a set and §7.5 makes the
// order the discriminator — the same reason `read_file` could not be a `prim_fn`.
//
// The round trip is the test that matters: §8 requires the two implementations of an
// intrinsic to agree, and writing bytes out and reading them back checks both halves
// against each other rather than against an assumption.
$decl path "/tmp/mpl_write_fixture.txt"

$decl wrote $call write_file (path, "morphl")

// 1 if the write reported success, 0 if it reported `err`.
$decl ok $match wrote ($case {$prop tag "err"} 0, $case wrote 1)

// What came back: the length of the contents, or -1 if it could not be read.
$decl back $call read_file (path)
$decl n    $match back ($case {$prop tag "some"} ($call len (back.v)), $case back -1)

// A path that cannot be created must report `err`, not panic — a directory that does
// not exist is the cheapest way to ask for one.
$decl bad   $call write_file ("/nonexistent-dir-mpl/x", "y")
$decl badok $match bad ($case {$prop tag "err"} 1, $case bad 0)

// 1 + 60 + 100 = 161, and each digit is one of the three claims: the write reported
// success, six bytes came back, and the impossible path reported `err` rather than
// panicking.
$decl main $func ()
  $call add (ok, $call add ($call mul (n, 10), $call mul (badok, 100)))
