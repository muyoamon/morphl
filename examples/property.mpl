$syntax "grammar_sample.txt";
y := {
  a := 1;
};
x := {
  a @= 1;
  b @= 2;
};
p := x.$a;
