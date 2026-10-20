// A host-platform smoke runner for the compiled-mode driver: the same checks
// the Linux/Windows cells run, executable from any development machine.
#include "run.h"

int main(void) { return run_greeter_compiled(); }
