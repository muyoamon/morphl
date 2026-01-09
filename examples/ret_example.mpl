$syntax "examples/grammar_sample.txt";
return 0;
factorial := (n := 0) => {
    if (n <= 1) {
        return 1;
    };
    return n * factorial(n-1);
};