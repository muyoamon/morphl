$syntax "grammar_sample.txt";
double := (n := 0) => { return n + n; };
result := double(21);
