// `import_order.mpl`'s module, which has an `$import` of its own after an effect.
$call print ("m1 ")
$decl I $import "import_order_inner"
$call print ("m2 ")
$defer $call print ("dm ")
$decl v $call add (I.w, 1)
