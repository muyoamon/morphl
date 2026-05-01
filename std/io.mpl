$decl _close_file_fields $extern "close_file_fields" $func ($decl handle 0, $decl owned 0, $decl ok 0) 0;
$decl _free_line_raw $extern "free_line_raw" $func ($decl raw 0) 0;
$alias File {
  $decl handle 0;
  $decl owned 0;
  $decl ok 0;
  $defer $call _close_file_fields (handle, owned, ok);
};


$alias Line {
  $decl text "";
  $decl len 0;
  $decl raw 0;
  $decl ok 0;
  $defer $call _free_line_raw (raw);
};



$decl _stdout_file $extern "stdout_file" $func () File;
$decl _stderr_file $extern "stderr_file" $func () File;
$decl _stdin_file $extern "stdin_file" $func () File;
$decl open $extern "open_file" $func ($decl path "", $decl mode "") File;
$decl close $extern "close_file" $func ($decl file File) 0;
$decl write $extern "write_file" $func ($decl file File, $decl text "") 0;
$decl writeln $extern "writeln_file" $func ($decl file File, $decl text "") 0;
$decl flush $extern "flush_file" $func ($decl file File) 0;
$decl read_line $extern "read_line" $func ($decl file File) Line;
$decl print $extern "print" $func ($decl text "") 0;
$decl println $extern "println" $func ($decl text "") 0;
$decl print_int $extern "print_int" $func ($decl n 0) 0;

$decl stdout $static $call _stdout_file ();
$decl stderr $static $call _stderr_file ();
$decl stdin $static $call _stdin_file ();
