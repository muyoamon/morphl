// `override.mpl`'s module: a template whose `has` asks the element's own `same` member,
// which no primitive has, so `$specialize box ""` fails in `has` — the case STDLIB.md's
// D3a is about. `step` is also a name in `override.mpl`, meaning something else there.
$decl step $func ($decl n 0) $call add (n, 100)

$decl box $template T {
  $prop make  $func ($decl x T) { $decl item x }
  $prop has   $func ($decl b ($call make (T)), $decl y T) $call b.item.same (y)
  $prop size  $func ($decl b ($call make (T))) $call step (1)
  $prop count $func ($decl b ($call make (T)), $decl y T)
    $if ($call has (b, y)) ($call size (b)) 0
}

// D3a's shape: one name for every element type, chosen by bounds (P7), with the `Str`
// candidate derived from the base. Inside a template body, so the override's `T` is this
// template's generic, renamed past the base's own.
$decl boxes $overload (
  $template ($decl T "")
    $specialize ($override box {
      $prop has $func ($decl b ($call make (T)), $decl y T) $call eq (b.item, y)
    }) T,
  box)
