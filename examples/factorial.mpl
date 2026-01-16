$syntax "grammar_sample.txt";
block := {
    a := 0;
    b := "Hello World";
};
fact := (n := 0) => {
    if (n <= 1) {
        return 1;
    } else {
        return n * fact(n-1);
    };
};