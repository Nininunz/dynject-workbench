// A dylib that calls the provider through its own imports.
int dhih_value2(int x);
int dhih_call_from_dylib(int x) { return dhih_value2(x); }
