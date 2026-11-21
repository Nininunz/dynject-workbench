// Loaded by the host after the probe's hooks exist.
int dhih_value4(int x);
int dhih_call_late(int x) { return dhih_value4(x); }
