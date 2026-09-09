/*
 * Local shim for the riscv32 cross toolchain.
 *
 * The riscv64-linux-gnu libc headers shipped on this host do not provide
 * gnu/stubs-ilp32.h, and /usr is read-only in this environment.  AM programs
 * are freestanding and never link against that libc, so an empty stubs file
 * placed ahead of the system include path is sufficient.  (See the RTFM
 * lecture note on fixing riscv32 compile errors.)
 */
