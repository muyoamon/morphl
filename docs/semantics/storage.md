# Morphl Storage Semantics

## Variable
Variables in Morphl can be declared without explicit type annotations. The type is inferred from the initial value assigned to the variable.

```mpl
    $decl x 42;            // 'x' is inferred to be of type int
    $decl name "Morphl";   // 'name' is inferred to be of type string
```
Morphl's variable are always initialized upon declaration. 

Notes: Having variable as initial value (e.g. `$decl x y;`) where y is mutable will throw warning: implicit mutable reference. This is because the variable y may change later, leading to unexpected behavior. To avoid this, either use `$decl x $mut y;` to explicitly declare x as new mutable reference, or use `$decl x $inline y;` to declare x as alias to y.

## Mutability
By default, variables in Morphl are immutable. To declare a mutable variable, use the `$mut` keyword.

```mpl
    $decl counter $mut 0;   // 'counter' is mutable
    $set counter 5;         // Valid assignment

    $decl constant 10;      // 'constant' is immutable
    $set constant 15;       // Error: cannot assign to immutable variable
```
`$mut` keyword will create a mutable cell that can be updated later using the `$set` operation.

Similarly, variables can be forced to be immutable using the `$const` keyword, this is useful when the initial value is mutable but you want to prevent further modifications. Usage of `$const` on an already immutable variable is also allowed.

```mpl
    $decl pi $const 3.14;   // 'pi' is immutable
    $set pi 3.1415;         // Error: cannot assign to immutable variable
```

Similarly to `$mut`, `$const` creates an immutable cell that cannot be updated after initialization.

Important Notes: Both `$mut` and `$const` will create a new cell for the variable, meaning that the variable will not directly reference the initial value if it is already a variable. This prevents accidental mutations through aliasing.

## Lifetime
Variables in Morphl have a lexical scope and lifetime. A variable declared within a block is only accessible within that block and its nested blocks.

```mpl
    {
        $decl temp 100;     // 'temp' is accessible here
        {
            $decl nestedTemp 200; // 'nestedTemp' is accessible here
        }
        // 'nestedTemp' is not accessible here
    }
    // 'temp' is not accessible here
```

However, variables should have an extended lifetime if they are binded to variables in an outer scope.

```mpl
    $decl outside $member {
        $decl inside 50;
    } inside; // `outside` now carry the lifetime of `inside` outside the block

    // However, direct assignment does not extend lifetime:

    $decl outside $mut 0;
    {
        $decl inside 50;
        $set outside inside;    // becomes invalid after this block ends (dangling reference)
        $set outside 100;       // this works fine (immediate value)
    }
```

## `$inline` Keyword
The `$inline` keyword can be used to tell the compiler that a variable's value should be inlined at its usage sites.

```mpl
    $decl Pos $inline {
        $decl x 0;
        $decl y 0;
    };
    $decl point Pos;   // 'point' is always an inlined instance of 'Pos'
```

It also has its use in to capture/extend lifetime of a variable without creating a new cell:

```mpl
    $decl makeCounter $func () {
        $decl count $mut 0;
        $decl inc $func () {
            $decl inner_count $inline count;        // 'inner_count' is an inline reference to 'count', extending its lifetime without creating a new cell 
            $set inner_count $add inner_count 1;   // modifies 'count' through 'inner_count'     
            $ret inner_count;                       // return the current count
        };
        $ret inc;    // return the 'inc' function which has access to 'count'
    };
```

## `$set` Operation
The `$set` operation is used to assign a new value to a mutable variable. The type of the new value must be compatible with the variable's inferred type.

```mpl
    $decl score $mut 10;    // 'score' is inferred to be of type int
    $set score 20;          // Valid assignment

    $set score "high";      // Error: type mismatch, cannot assign string to int
```

Notes: The `$set` operation does not change the type of the variable; it only updates the value it references. Thus, `$set` operation does not extend the lifetime of the assigned value.

## Function arguments semantics
morphl function arguments are treated as a single object. When the function is called through `$call` operation, the arguments are evaluated and grouped together as a single value, and passed to the function as reference. If the arguments is passed by immediate expression, any modification of argument inside the function will not affect the original argument outside the function. However, if the argument is passed by variable reference, modification of the argument inside the function will affect the original variable outside the function.

```mpl
    $decl modifyArgs $func ($decl args $mut (0, 0)) {
        $set args (1, 1);     // Modifying the group does not affect the original arguments
        $ret args;            // Returns the modified group
    };

    $decl originalArgs $mut (0, 0);
    $call modifyArgs $inline originalArgs;   // originalArgs changes to (1, 1) due to pass-by-reference semantics
    $call modifyArgs originalArgs;           // originalArgs does not change, remains (0, 0) since sole expression is passed by value (immediate expression)
```

This would make the function declaration determine the contract (i.e. whether the argument is mutable or not) and the caller can decide whether to pass by value or by reference.

Of course, we could extend the pass-by-value/reference semantics from call sites to function declaration contracts by:
```mpl
    // by expecting an inline group argument, the function contract requires the caller to pass by reference, and any modification to the argument inside the function will affect the original variable outside the function.
    $decl someFunc $func (
        $decl arg1 $inline $mut 0   // inline argument (pass by reference)
        $decl arg2 $mut 0           // non-inline argument (pass semantics determined by call site)
     ) {
        ... // function body
    };

    $decl var1 $mut 0;
    $decl var2 $mut 0;
    $call someFunc ($inline var1, var2);   // var1 is passed by reference, var2 is passed by value
    
```