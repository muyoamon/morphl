// §7.8: `panic` aborts, and what the program printed before it is still printed. The
// emitted runtime did not flush: stdout to a pipe or a file is buffered and `abort` drops
// the buffer, so a compiled program lost its last output where stage 0 kept it.
$decl main $func () $do ($call print ("before\n")) ($call panic ("boom"))
