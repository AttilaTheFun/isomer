// The console bench's entry point as compiled into the iOS bench app (its
// `main` renamed via -Dmain=...; see BUILD.bazel).
#pragma once

int iso_wamr_bench_main(int argc, char **argv);
