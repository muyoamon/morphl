// `overload_tmpl.mpl`'s module: an overload of templates resolved inside the module that
// declares it, and from the file importing it, which records its choice under another
// file's name (`note_over`'s key).
$decl small $template ($decl T 0) $func ($decl x T) $call add (x, 100)
$decl other $template T $func ($decl x T) 0
$decl pick  $overload (small, other)
$decl use   $func () $call pick (5)
