# Morphl Typing
This document describes the typing system used in Morphl.

Notes: this document assumes 'minimal syntax'

## Type Inference
Morphl does not have explicit type annotations in the source code. Instead, it uses a type inference system to deduce the types of variables and expressions based on their usage.

```mpl
    $decl x 42;          // 'x' is inferred to be of type 'int'
    $decl y "hello";     // 'y' is inferred to be of type 'string'
```

## Block Type
Blocks in Morphl can contain multiple statements; It could even contains statements. The type of a block is determined by the type of its `$decl` expressions.

```mpl
    {
        $decl a 10;
        $decl b 20;
        $add a b;            
    } // The block's type is inferred to be {a:int, b:int}
```

## Group Type
Groups are collections of unnamed values. The type of a group is inferred from the types of its elements.

```mpl
    1, "two", 3.0;     // Inferred type: (int, string, float)
```

### Synonimous with single-element group
Morphl treats single-element groups as equivalent to their contained type. Thus, a group with one element infers to the type of that element.

```mpl
    $decl singleElemGroup $group 42;        // Inferred type: int
    $decl anotherSingleElemGroup 42;        // Inferred type: int
```

## Function Type
Functions in Morphl can be defined without explicit type annotations. The types of return values are inferred from within the function body.

```mpl
    $decl add $func ($decl a 0, $decl b 0) {
        $ret $add a b;          // The types of add infer from `$ret` expression
    };

    // or

    $decl add $func ($decl a 0, $decl b 0) $add a b;          // blockless function, no `$ret` needed 
```

Notes: `$func` takes two operands: a parameter list and a function body. The parameter list consists of `$decl` expressions within a group that define the parameters and their default values. The function body can be a block or a single expression.

## Subtype Relations
Morphl supports subtype relations, allowing for more flexible type assignments. For example, a variable of type `(int, int, int)` can be assigned to a variable of type `(int, int)` if the first two elements match.

```mpl
    $decl point2D $mut (0, 0);               // point2D is of type (int, int)
    $decl point3D $mut (0, 0, 0);            // point3D is of type (int, int, int)

    $set point2D point3D;               // Valid assignment due to subtype relation
```

However, the reverse is not true; a variable of type `(int, int)` cannot be assigned to a variable of type `(int, int, int)`.
Similarly, a block of type `{x:int, y:int, z:int}` can be assigned to a variable of type `{x:int, y:int}`.
```mpl
    $decl position2D $mut {
        $decl x 0;
        $decl y 0;
    };

    $decl position3D $mut {
        $decl x 0;
        $decl y 0;
        $decl z 0;
    };

    $set position2D position3D;         // Valid assignment due to subtype relation
```
However, the third member `z` in `position3D` has no corresponding member in `position2D`, so the `z` value becomes inaccessible through `position2D`. The member could still be accessed if assigned to `position3D`.

## Void Type
Morphl does not include explicit `void` types. However, void-like behavior could be achieved using empty group.

```mpl
    $decl doNothing $func () () // Empty body, effectively returns an empty group;
```

Notes: Due to subtyping rules, an empty group is considered a subtype of any type.

