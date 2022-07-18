# RISC-V-Traps
Traps for RISC-V

This repo has a trap handler (RISC-V ASM) to provide software emulation of misaligned memory loads.
Supports only LW and C.LW.
It was tested on FE310-G002 which does not provide hardware support for misaligned data accesses.

Should be able to solve the misalingned load on any register except SP, in which case it will solve the access but will use register T5 as scratchpad memory.
