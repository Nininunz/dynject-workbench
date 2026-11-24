// Test functions for DHHookFunction: each starts with the instruction kind it tests, so moving its first four
// instructions to the trampoline has to rewrite that kind. arm64 only.
.text
.p2align 2

.globl _f_adrp
_f_adrp:                        // adrp + add (page offset): returns g_value (7)
    adrp x0, _g_value@PAGE
    add  x0, x0, _g_value@PAGEOFF
    ldr  w0, [x0]
    add  w0, w0, #0
    ret

.globl _f_adr
_f_adr:                         // adr: returns 11
    adr  x1, Ladr
    ldr  w0, [x1]
    nop
    nop
    ret
    .p2align 2
Ladr: .long 11

.globl _f_ldrx
_f_ldrx:                        // ldr x (literal): returns 0x1122334455667788
    ldr  x0, Lq
    nop
    nop
    nop
    ret
    .p2align 3
Lq: .quad 0x1122334455667788

.globl _f_ldrw
_f_ldrw:                        // ldr w (literal): returns 0x12345678
    ldr  w0, Lw
    nop
    nop
    nop
    ret
    .p2align 2
Lw: .long 0x12345678

.globl _f_ldrsw
_f_ldrsw:                       // ldrsw (literal): returns -5
    ldrsw x0, Lsw
    nop
    nop
    nop
    ret
    .p2align 2
Lsw: .long -5

.globl _f_ldrd
_f_ldrd:                        // ldr d (literal): returns 2.5
    ldr  d0, Ld
    nop
    nop
    nop
    ret
    .p2align 3
Ld: .double 2.5

.globl _f_bl
_f_bl:                          // bl in the third instruction: returns helper() + 1 = 42
    stp  x29, x30, [sp, #-16]!
    mov  x29, sp
    bl   _f_helper
    add  w0, w0, #1
    ldp  x29, x30, [sp], #16
    ret

.globl _f_helper
_f_helper:
    mov  w0, #41
    ret

.globl _f_bcond
_f_bcond:                       // b.cond: x < 5 → 200, else 100
    cmp  w0, #5
    b.lt 1f
    mov  w0, #100
    nop
    ret
1:  mov  w0, #200
    ret

.globl _f_cbz
_f_cbz:                         // cbz: 0 → 2, else 1
    cbz  w0, 1f
    mov  w0, #1
    nop
    nop
    ret
1:  mov  w0, #2
    ret

.globl _f_tbz
_f_tbz:                         // tbz: bit 3 clear → 2, set → 1
    tbz  w0, #3, 1f
    mov  w0, #1
    nop
    nop
    ret
1:  mov  w0, #2
    ret

.globl _f_b3
_f_b3:                          // b as the fourth instruction: returns 9
    nop
    nop
    nop
    b    1f
    brk  #1
1:  mov  w0, #9
    ret

.globl _f_short
_f_short:                       // 8 bytes: must be refused
    mov  w0, #1
    ret

.globl _f_loop
_f_loop:                        // branches back into its first 16 bytes: must be refused
    mov  w1, #0
1:  add  w1, w1, #1
    cmp  w1, w0
    b.lt 1b
    mov  w0, w1
    ret
