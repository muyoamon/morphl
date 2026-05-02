$syntax "grammar_sample.txt";
fact := (n := 0) => {
    if (n <= 1) {
        return 1;
    } else {
        return n * fact(n-1);
    };
};

