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
Two types are considered to be in a subtype relation if one type can be used in place of the other without causing type errors. In case of morphl ABI, a type A is a subtype of type B if values of type A can be safely used in contexts that expect values of type B.

Morphl supports subtype relations, allowing for more flexible type assignments. For example, a variable of type `(int, int, int)` can be assigned to a variable of type `(int, int)` if the first two elements match.

```mpl
    $decl point2D $mut (0, 0);               // point2D is of type (int, int)
    $decl point3D $mut (0, 0, 0);            // point3D is of type (int, int, int)

    $set point2D point3D;               // Valid assignment due to subtype relation
```

Similarly, a block of type `{x:int, y:int, z:int}` can be assigned to a variable of type `{x:int, y:int}`.
However, the reverse is not true; a variable of type `(int, int)` cannot be assigned to a variable of type `(int, int, int)`.

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

Notes: Since empty group does not carry any meaningful value, it is essentially a subtype of all types, meaning it can be used in any context without causing type errors. This allows for flexible function definitions that do not require a specific return type.

## Properties
In morphl, properties are a special kind of member that can be accessed using `$member` operator with `$` prefix. Properties of a type is checked separately from the type itself, meaning that for a type to be a subtype of another type that has properties, it must have the same properties with compatible types.

Properties are setted upon initialization and cannot be changed later, meaning that they are effectively constant. This allows for defining types with fixed properties that can be used in subtype relations without worrying about mutability issues.

```mpl
    $decl typeA {
        $decl x 10;
        $decl y 20;
        $prop propA 30;     // 'propA' is a property of typeA
    };

    $decl typeB {
        $decl x 0;
        $decl y 0;
    };

    $decl typeC {
        $prop propA 30;     // 'propA' is a property of typeC
        $decl x 0;
        $decl y 0;
    };

    // accessing properties
    $member typeA $propA;   // Valid access, returns 30

    $set typeB typeA;   // Valid assignment, typeB is a subtype of typeA
    $set typeC typeA;   // Valid assignment, typeC is a subtype of typeA
    $set typeA typeB;   // Error: typeA is not a subtype of typeB due to missing property 'propA'

    // Noted that properties are not sequentially checked, meaning that the order of properties does not affect subtype relations:
```

## Traits
Traits are a way to define shared behavior across different types. A trait defines a set of properties that can be implemented by any type. A type that implements a trait must provide implementations for all the properties defined in the trait.

```mpl
    $decl TraitA  $traits {
        $prop propA 30;     // 'propA' is a property of TraitA
        $prop methodB $func () 0;   // 'methodB' is a method property of TraitA
        // traits object can only have properties, it cannot have regular members. This is because traits are meant to define behavior that can be shared across different types, and having regular members would make it difficult to implement the trait for different types with different member requirements.
    };

    $decl typeD {
        $decl x 0;
        $decl y 0;
    };

    // Implementing TraitA for typeD
    // `$impl` takes atleast two operands:
    // 1. The trait to be implemented (TraitA)
    // 2. The type that implements the trait (typeD)
    // 3. (Optional) A block that provides the implementations for the trait's properties. If the block is omitted, The implementation for that type will use the default implementations provided in the trait.
    // Note that the type in morphl cannot change after declaration, so the implementation block will not be able to add new properties to the type. Instead, it will create a new type that has the same properties as the original type plus the properties defined in the trait. This means that the original type will not be modified, and the new type will be a subtype of the original type.
    $decl typeE $impl TraitA typeD {
        $prop propA 30;     // Implementing 'propA' for typeD
        $prop methodB $func () 0;   // Implementing 'methodB' for typeD
    }

```

Traits object can also be used as a type, meaning that a variable can be declared to be of a trait type, and it can hold any value that implements that trait.

```mpl
    $decl traitVar TraitA;   // 'traitVar' can hold any value that implements TraitA

    $set traitVar typeE;     // Valid assignment, typeE implements TraitA
    $set traitVar typeD;     // Error: typeD does not implement TraitA
```



