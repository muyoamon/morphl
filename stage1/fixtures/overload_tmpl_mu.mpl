// An overload's choice recorded inside a template instance whose argument is a block
// inference closes into a `μ` only through a prop's *type*: `plus` takes another of its
// own block (§4.10), as a list wrapper's `append` does. Lowering derives a specialisation's
// types itself and keeps a prop's identity, not its type, so it has nothing to close — and
// both passes key the instance by its argument types rendered, `mu.{k:Int,…}` against
// `{k:Int,…}`. Lowering missed the choice and called the overload as if it were a function
// value, which is C that does not compile. `T.show_key` renders such a `μ` as its body.
// 2, then 1 for the `Int` instance of the same site, then 0 through a module's overload.

$decl U $import "overload_tmpl_util"

$decl boxes $template T {
  $prop wrap $func ($decl n T) {
    $decl w   {
      $decl k n
      $prop plus $func ($decl o w) $call wrap (o.k)
    }
    $decl ret w
  }.ret
}
$decl ints $specialize boxes 0

$decl int_one $func ($decl x 0) 1
$decl any_two $template T $func ($decl x T) 2
$decl pick    $overload (int_one, any_two)
$decl via     $template T $func ($decl x T) $call pick (x)
$decl via_u   $template T $func ($decl x T) $call U.pick (x)

$decl main $func ()
  $call add ($call mul ($call via ($call ints.wrap (1)), 100),
      $call add ($call mul ($call via (5), 10), $call via_u ($call ints.wrap (1))))
