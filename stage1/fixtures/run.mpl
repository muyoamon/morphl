// BOOTSTRAP §2's `run (argv)`: an exit status, the status a shell would give a
// signal, and `none` for a program that cannot be started — in both stages, so
// `test-run0` compares them. The argv goes to the program as it is, with no shell
// between, so "exit 7" is one argument to `sh -c`.
//
// 0 + 1 * 10 + 7 * 100 + 137 * 1000 - 1 * 100000 = 37710: `true`, `false`, `exit 7`,
// SIGKILL (128 + 9), and the missing program.

$decl argv1 $func ($decl a "") $call array (1, a)

$decl argv3 $func ($decl a "", $decl b "", $decl c "") {
  $decl av  $call array (3, a)
  $decl p1  $call at (av, 1)
  $decl w1  $set p1 b
  $decl p2  $call at (av, 2)
  $decl w2  $set p2 c
  $decl ret av
}.ret

// The status, or -1 when `run` answered `none`.
$decl status $func ($decl av $call array (0, "")) {
  $decl r   $call run (av)
  $decl ret $match r ($case {$prop tag "some"} r.v, $case r -1)
}.ret

$decl main $func () {
  $decl s0  $call status ($call argv1 ("true"))
  $decl s1  $call status ($call argv1 ("false"))
  $decl s2  $call status ($call argv3 ("sh", "-c", "exit 7"))
  $decl s3  $call status ($call argv3 ("sh", "-c", "kill -9 $$"))
  $decl s4  $call status ($call argv1 ("./no-such-program-anywhere"))
  $decl ret $call add ($call add ($call add (s0, $call mul (s1, 10)), $call mul (s2, 100)),
                $call add ($call mul (s3, 1000), $call mul (s4, 100000)))
}.ret
