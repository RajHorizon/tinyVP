/*
 * Copyright (c) 2017 Leonid Yegoshin
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files
 * (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge,
 * publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include    "tinyVP.h"
#include    "mipsasm.h"

.section .text.init, "ax"
	.set    virt

	.set    push
	.set    noreorder
	.set    noat

//
//                  tinyVP starts here
//

	// set to page alignment for exception vector

	.align  12
	.set BOOTOFFSET, .
	.org    BOOTOFFSET + 0x0

.type TLB_refill, @function
	.globl  TLB_refill
TLB_refill:
	mfc0    k1, CP0_CONTEXT
	sll     k1, 1           // destroy flag bit
	mtc0    t3, CP0_KSCR1   // save 3-rd register in KSCR1
	srl     k1, 24          // k1 - CPT index in CPTs array
	sll     k1, 2           // k1 - offset in bytes
	la      t3, cpt_base
	addu    t3, k1
	mfc0    k0, CP0_BADVADDR
	lw      k1, 0(t3)       // k1 - address of top CPT level - 8 elements
	move    t3, $0
	ext     t3, k0, 29, 3   // extract top 3 bits
	sll     t3, 4           // * 16bytes -> offset in top table
	add     k1, t3
	lw      t3, 4(k1)
	addiu   k0, $0, -1      // max pagemask in MIPS32 == 256MB * 2
	rotr    t3, t3, 1
	bgez    t3, leaf_entry  // test leaf element
	 sll    t3, 1           // restore t3 and clear a flag bit
				// k1 - base addr of top CPT element
				// t3 - mask of address
				// k0 - pagemask (flagword)
parse_cpte:
conti:
	mfc0    k0, CP0_BADVADDR    // address
	and     k0, t3      // k0 is address bits to check
	lw      t3, 8(k1)   // t3 is address bits golden
	bne     k0, t3, bad_area
	 nop

	lw      k0, 12(k1)  // k0 - flag word
	lw      k1, 0(k1)   // k1 - addr of next CPT level

	mfc0    t3, CP0_BADVADDR    // address
	sllv    t3, t3, k0
	srl     k0, 5       // get a right shift value
	srlv    t3, t3, k0
			    // t3 - index in next level CPT
			    // k1 - addr of next CPT level
	ins     t3, $0, 0, 4  // next level offset in blocks
			    // t3 - parts of bits for offset ready
			    // k1 - addr of next CPT level
	sll     k0, 5       // k0 - restore page mask
	add     k1, t3      // k1 - base addr of CPTE

	lw      t3, 4(k1)   // t3 load mask
	rotr    t3, t3, 1   // test leaf element
	bltz    t3, parse_cpte
	 sll    t3, 1       // restore t3 and clear a flag bit

leaf_entry:                 // k1 - leaf cpte address
			    // k0 - page mask

tlbrefill:
	mtc0    k0, CP0_PAGEMASK    // PageMask from previous level flagword
	lw      t3, 8(k1)   // t3 - first ELo
	lw      k0, 12(k1)  // k0 - second ELo
			    // no protection is assumed
	ins     t3, $0, 0, 1        // clear "write-ignore" (G-bit)
	mtc0    t3, CP0_ENTRYLO0
	ins     k0, $0, 0, 1        // clear "write-ignore" (G-bit)
	mtc0    k0, CP0_ENTRYLO1
	mfc0    k1, CP0_ENTRYHI
	ins     k1, $0, 10, 1   // Clear EHINV
	mtc0    k1, CP0_ENTRYHI
	ehb
	tlbwr
	ehb
	or      k1, k0, t3
	beqz    k1, bad_area
	 mfc0   t3, CP0_KSCR1
	eret

bad_area:
	j       EXC_entry
	 mfc0   t3, CP0_KSCR1

// ================= PIC32MZEF bootloader required data ====================
	.org    BOOTOFFSET + 0xf8
	.type   _ebase, @object
.globl  _ebase
_ebase:
	.word   TLB_refill                      # EBase value

	.type   _imgptr, @object
	.org    BOOTOFFSET + 0xfc
_imgptr:
	.word   -1                              # Image header pointer

// ==================================================

	.org    BOOTOFFSET + 0x100
cacheerr:
	b       cacheerr
	 nop

// ==================================================

	.org    BOOTOFFSET + 0x180

EXC_entry:
	mfc0    k0, CP0_CONTEXT
	ext     k1, k0, CP0_CONTEXT_VM_SHIFT, CP0_CONTEXT_VM_LEN + 1
	bnez    k1, EXC_nonexc_entry      // idle or guest or thread
	 mfc0   k1, CP0_GUESTCTL0

	bltz    k1, _clear_g_ll_cont    // exit to ERET during G.LLbit clearing
	 nop

	j       EXC_entry_continue
	 nop

// ==================================================

.type _bzero, @function
	.globl  _bzero
_bzero:
	andi    at, a0, 0x3
	bnez    at, 20f     // unaligned...
	 nop

	addiu   a1, -4
	bltz    a1, 15f
	 nop
	// a1 less than size by 4, size >=4
10:
	sw      $0, 0(a0)
	addiu   a1, -4
	bgez    a1, 10b
	 addiu  a0, 4

15:
	addiu   a1, 4   // restore length
20:
	blez    a1, 30f
25:
	 addiu   a1, -1
	sb      $0, 0(a0)
	bgtz    a1, 25b
	 addiu  a0, 1
30:
	jr      ra
	 nop


// =================================================

	.org    BOOTOFFSET + 0x200

IRQ_entry:
	// Guest uses SRS, so we are free to use K0/K1 (Thread doesn't use it)
	mfc0    k0, CP0_CONTEXT
	ext     k1, k0, CP0_CONTEXT_VM_SHIFT, CP0_CONTEXT_VM_LEN + 1
	bnez    k1, IRQ_nonexc_entry // idle or guest or thread
	 mfc0   k1, CP0_STATUS

#if (BOOTOFFSET != 0)
	b       IRQ_entry_continue
	 nop

// =================================================

	.org    BOOTOFFSET + 0x280
	deret

// =================================================

IRQ_entry_continue:
#endif
// IRQ on top of IRQ or exception on top of IRQ or main kernel thread
// FP, GP, SP are valid. K0/K1 can be used
// save critical registers while interrupt is disabled
	sw      sp, PTR_SP - FULL_INTERRUPT_FRAME_SIZE(sp)  // sp
	addiu   sp, sp, - FULL_INTERRUPT_FRAME_SIZE - ARGS_FRAME_SIZE

	mfc0    k1, CP0_GUESTCTL0
	sw      k0, PTR_CP0_CONTEXT + ARGS_FRAME_SIZE(sp)
	sw      k1, PTR_CP0_GUESTCTL0 + ARGS_FRAME_SIZE(sp)
	ins     k1, $0, CP0_GUESTCTL0_GM_SHIFT, 1

	mfc0    k0, CP0_EPC
	mtc0    k1, CP0_GUESTCTL0
	sw      k0, PTR_CP0_EPC + ARGS_FRAME_SIZE(sp)
	mfc0    k0, CP0_STATUS
	mfc0    k1, CP0_SRSCTL
	sw      k1, PTR_CP0_SRSCTL + ARGS_FRAME_SIZE(sp)

	lui     k1, %hi(CP0_STATUS_CU0)
	addiu   k1, CP0_STATUS_MODE | CP0_STATUS_EXL | CP0_STATUS_IE
	or      k1, k0
	sw      k0, PTR_CP0_STATUS + ARGS_FRAME_SIZE(sp)
	xori    k1, CP0_STATUS_MODE | CP0_STATUS_EXL | CP0_STATUS_IE
	mtc0    k1, CP0_STATUS  // and disable IE, enable CU0, kernel mode, no EXL
//        ehb
//  save EIC interrupt number value here
//        mfc0    k0, CP0_RIPL            // !!!!
//        mtc0    k0, CP0_IPL             // !!!!

// interrupts may be  enabled now, then we put here EIC IRQ read
	.irp    reg, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, \
		    17, 18, 19, 20, 21, 22, 23, 24, 25, 31
	sw      $\reg, PTR_GPR + \reg * 4  + ARGS_FRAME_SIZE(sp)
	.endr
	mflo    t0
	mfhi    t1
	sw      t0, PTR_LO + ARGS_FRAME_SIZE(sp)
	sw      t1, PTR_HI + ARGS_FRAME_SIZE(sp)

	jal     do_IRQ
	 addiu  a0, sp, ARGS_FRAME_SIZE
IRQ_exit:

	lw      t0, PTR_LO + ARGS_FRAME_SIZE(sp)
	lw      t1, PTR_HI + ARGS_FRAME_SIZE(sp)
	mtlo    t0
	mthi    t1
	.irp    reg, 1, 2, 3, 4, 5, 6, 7, /* 8, */ 9, 10, 11, 12, 13, 14, 15, 16, \
		    17, 18, 19, 20, 21, 22, 23, 24, 25, 31
	lw      $\reg, PTR_GPR + \reg * 4 + ARGS_FRAME_SIZE(sp)
	.endr

// disable interrupts and guest enter
	mfc0    t0, CP0_STATUS
	ori     t0, CP0_STATUS_EXL
	mtc0    t0, CP0_STATUS
	ehb
// interrupts are disabled now
	lw      t0, PTR_GPR + 8 * 4  + ARGS_FRAME_SIZE(sp)    // t0 = $8
	lw      k1, PTR_CP0_SRSCTL + ARGS_FRAME_SIZE(sp)
	lw      k0, PTR_CP0_EPC + ARGS_FRAME_SIZE(sp)
	mtc0    k1, CP0_SRSCTL
	mtc0    k0, CP0_EPC
	lw      k1, PTR_CP0_GUESTCTL0 + ARGS_FRAME_SIZE(sp)
	lw      k0, PTR_CP0_CONTEXT + ARGS_FRAME_SIZE(sp)
	mtc0    k1, CP0_GUESTCTL0
	mtc0    k0, CP0_CONTEXT
	ehb
// final CP0 status return
	lw      k0, PTR_CP0_STATUS + ARGS_FRAME_SIZE(sp)
	ori     k0, CP0_STATUS_EXL
	lw      sp, PTR_SP + ARGS_FRAME_SIZE(sp)              // sp = $29
	mtc0    k0, CP0_STATUS
	ehb
	eret

IRQ_nonexc_entry:
			// k0 - Context
			// k1 - Status
			// if !KSU, then FP, GP are expected to be OK
	ext     k1, k1, CP0_STATUS_KSU_SHIFT, CP0_STATUS_KSU_LEN
	beqz    k1, 10f // kernel mode
	 move   k1, fp
//  Non-root.kernel mode, restore basics
	mfc0    k1, CP0_KSCR0                   // FP
	sw      fp, PTR_FP(k1)
	sw      gp, PTR_GP(k1)
	la      gp, _gp
10:
	sw      sp, PTR_SP(k1)
	move    fp, k1
	lw      sp, %gp_rel(irq_sp)(gp)          // WAIT or VMx mode, so - stack is idle
	sw      k0, PTR_CP0_CONTEXT(fp)
	addiu   sp, - ARGS_FRAME_SIZE
	mfc0    k1, CP0_EPC
	mtc0    $0, CP0_CONTEXT     // clear IDLE flag and switch to root-kernel
	sw      k1, PTR_CP0_EPC(fp)

// save critical registers while interrupt disabled
	mfc0    k0, CP0_GUESTCTL0
	sw      k0, PTR_CP0_GUESTCTL0(fp)
	ins     k0, $0, CP0_GUESTCTL0_GM_SHIFT, 1
	mtc0    k0, CP0_GUESTCTL0   // clear guest flag

	lui     k0, %hi(CP0_STATUS_CU0)
	mfc0    k1, CP0_STATUS
	addiu   k0, CP0_STATUS_MODE | CP0_STATUS_EXL | CP0_STATUS_IE
	or      k0, k1
	sw      k1, PTR_CP0_STATUS(fp)
	xori    k0, CP0_STATUS_MODE | CP0_STATUS_EXL | CP0_STATUS_IE
	mfc0    k1, CP0_SRSCTL
	mtc0    k0, CP0_STATUS          // disable IE, enable CU0, kernel mode, no EXL
//        ehb
//  save EIC interrupt number value here
//        mfc0    k0, CP0_RIPL            // !!!!
//        mtc0    k0, CP0_IPL             // !!!!
	sw      k1, PTR_CP0_SRSCTL(fp)
	ext     k1, k1, CP0_SRSCTL_PSS_SHIFT, CP0_SRSCTL_PSS_LEN
	bnez    k1, 10f
	 di                             // disable for now...
	ehb
// interrupts may be enabled now, then we put EIC IRQ # read as 'critical' reg
	.irp    reg, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, \
		    17, 18, 19, 20, 21, 22, 23, 24, 25, 31
	sw      $\reg, PTR_GPR + \reg * 4 (fp)
	.endr
10:
	ehb
	mflo    t2
	mfhi    t3
	sw      t2, PTR_LO(fp)
	sw      t3, PTR_HI(fp)

	jal     do_IRQ
	 addiu  a0, fp, 0

.type IRQ_nonexc_exit, @function
	.globl  IRQ_nonexc_exit
IRQ_nonexc_exit:

	lw      t0, PTR_HI(fp)
	lw      t1, PTR_LO(fp)
	mthi    t0
	lw      t0, PTR_CP0_SRSCTL(fp)
	ext     t0, t0, CP0_SRSCTL_PSS_SHIFT, CP0_SRSCTL_PSS_LEN
	bnez    t0, 10f
	 mtlo    t1
	.irp    reg, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, \
		    17, 18, 19, 20, 21, 22, 23, 24, 25, 31
	lw      $\reg, PTR_GPR + \reg * 4(fp)
	.endr
10:
// disable interrupts
	di
	ehb
// interrupts are disabled now, disable guest exit
	mfc0    k0, CP0_STATUS
	ori     k0, CP0_STATUS_EXL
	mtc0    k0, CP0_STATUS
	ehb
// restore the CP0
	lw      k1, PTR_CP0_SRSCTL(fp)
	lw      k0, PTR_CP0_EPC(fp)
	mtc0    k1, CP0_SRSCTL
	mtc0    k0, CP0_EPC
	lw      k1, PTR_CP0_GUESTCTL0(fp)
	lw      k0, PTR_CP0_CONTEXT(fp)
	mtc0    k1, CP0_GUESTCTL0
	mtc0    k0, CP0_CONTEXT
	ehb
// final CP0 status return
	mtc0    fp, CP0_KSCR0                   // FP
	lw      k0, PTR_CP0_STATUS(fp)
	ext     k1, k0, CP0_STATUS_KSU_SHIFT, CP0_STATUS_KSU_LEN
	beqz    k1, 10f
	 lw      sp, PTR_SP(fp)
	// non-kernel root context, restore GP, FP
	lw      gp, PTR_GP(fp)
	lw      fp, PTR_FP(fp)
10:
	ori     k0, CP0_STATUS_EXL
	mtc0    k0, CP0_STATUS
	ehb
	eret

// ========================================

EXC_entry_continue:
// Exception on top of IRQ or exception on top of exception or main kernel thread
// FP, GP, SP are valid. K0/K1 can be used
// save critical registers while interrupt is disabled
	sw      sp, PTR_SP - FULL_INTERRUPT_FRAME_SIZE(sp)  // sp
	addiu   sp, sp, - FULL_INTERRUPT_FRAME_SIZE - ARGS_FRAME_SIZE
	mfc0    k1, CP0_GUESTCTL0
	sw      k0, PTR_CP0_CONTEXT + ARGS_FRAME_SIZE(sp)
	sw      k1, PTR_CP0_GUESTCTL0 + ARGS_FRAME_SIZE(sp)
	ins     k1, $0, CP0_GUESTCTL0_GM_SHIFT, 1
	mfc0    k0, CP0_EPC
	mtc0    k1, CP0_GUESTCTL0
	sw      k0, PTR_CP0_EPC + ARGS_FRAME_SIZE(sp)
	mfc0    k1, CP0_BADVADDR
	mfc0    k0, CP0_BADINST
	sw      k1, PTR_CP0_BADVADDR + ARGS_FRAME_SIZE(sp)
	sw      k0, PTR_CP0_BADINST + ARGS_FRAME_SIZE(sp)
	mfc0    k1, CP0_BADINSTP
	mfc0    k0, CP0_NESTED_EPC
	sw      k1, PTR_CP0_BADINSTP + ARGS_FRAME_SIZE(sp)
	sw      k0, PTR_CP0_NESTED_EPC + ARGS_FRAME_SIZE(sp)
	mfc0    k1, CP0_NESTED_EXC
	mfc0    k0, CP0_CAUSE
	sw      k1, PTR_CP0_NESTED_EXC + ARGS_FRAME_SIZE(sp)
	sw      k0, PTR_CP0_CAUSE + ARGS_FRAME_SIZE(sp)
	mfc0    k1, CP0_SRSCTL
	sw      k1, PTR_CP0_SRSCTL + ARGS_FRAME_SIZE(sp)

	mfc0    k0, CP0_STATUS
	lui     k1, %hi(CP0_STATUS_CU0)
	addiu   k1, CP0_STATUS_MODE | CP0_STATUS_EXL | CP0_STATUS_IE
	or      k1, k0
	xori    k1, CP0_STATUS_MODE | CP0_STATUS_EXL | CP0_STATUS_IE
	sw      k0, PTR_CP0_STATUS + ARGS_FRAME_SIZE(sp)
	mtc0    k1, CP0_STATUS  // and disable IE, enable CU0, kernel mode, no EXL
	ehb
// interrupts may be enabled now
	.irp    reg, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, \
		    17, 18, 19, 20, 21, 22, 23, 24, 25, 31
	sw      $\reg, PTR_GPR + \reg * 4 + ARGS_FRAME_SIZE (sp)
	.endr
	mflo    t0
	mfhi    t1
	sw      t0, PTR_LO + ARGS_FRAME_SIZE(sp)
	sw      t1, PTR_HI + ARGS_FRAME_SIZE(sp)

	addiu   a0, sp, ARGS_FRAME_SIZE
	lui     ra, %hi(IRQ_exit)
	j       do_EXC
	 addiu  ra, %lo(IRQ_exit)

EXC_nonexc_entry:
			// k1 - GuestCtl0
			// k0 - Context
			// if CU0, then FP, GP are expected to be OK

	mfc0    k1, CP0_STATUS
	ext     k1, k1, CP0_STATUS_KSU_SHIFT, CP0_STATUS_KSU_LEN
	beqz    k1, 10f // kernel mode
	 move   k1, fp
//  Non-root.kernel mode, restore basics
	mfc0    k1, CP0_KSCR0                   // FP
	sw      fp, PTR_FP(k1)
	sw      gp, PTR_GP(k1)
	la      gp, _gp
10:
	sw      sp, PTR_SP(k1)
	move    fp, k1
	lw      sp, %gp_rel(irq_sp)(gp)          // WAIT or VMx mode, so - stack is idle
	sw      k0, PTR_CP0_CONTEXT(fp)
	ins     k0, $0, CP0_CONTEXT_WAITFLAG_SHIFT, 1   // clear "Idle" flag
	addiu   sp, - ARGS_FRAME_SIZE
	mtc0    k0, CP0_CONTEXT
	mfc0    k0, CP0_EPC
	mfc0    k1, CP0_GUESTCTL0
	sw      k0, PTR_CP0_EPC(fp)
	sw      k1, PTR_CP0_GUESTCTL0(fp)
	ins     k1, $0, CP0_GUESTCTL0_GM_SHIFT, 1
	mtc0    k1, CP0_GUESTCTL0   // clear G flag

// save critical registers while interrupt disabled

	mfc0    k1, CP0_CAUSE
	mfc0    k0, CP0_BADVADDR
	sw      k1, PTR_CP0_CAUSE(fp)
	sw      k0, PTR_CP0_BADVADDR(fp)
	mfc0    k1, CP0_BADINST
	mfc0    k0, CP0_BADINSTP
	sw      k1, PTR_CP0_BADINST(fp)
	sw      k0, PTR_CP0_BADINSTP(fp)
	mfc0    k1, CP0_NESTED_EPC
	mfc0    k0, CP0_NESTED_EXC
	sw      k1, PTR_CP0_NESTED_EPC(fp)
	sw      k0, PTR_CP0_NESTED_EXC(fp)

	lui     k0, %hi(CP0_STATUS_CU0)
	mfc0    k1, CP0_STATUS
	addiu   k0, CP0_STATUS_MODE | CP0_STATUS_EXL | CP0_STATUS_IE
	or      k0, k1
	sw      k1, PTR_CP0_STATUS(fp)
	xori    k0, CP0_STATUS_MODE | CP0_STATUS_EXL | CP0_STATUS_IE
	mfc0    k1, CP0_SRSCTL
	mtc0    k0, CP0_STATUS  // and disable IE, enable CU0, kernel mode, no EXL

	sw      k1, PTR_CP0_SRSCTL(fp)
	ext     k1, k1, CP0_SRSCTL_PSS_SHIFT, CP0_SRSCTL_PSS_LEN
	bnez    k1, 10f
	 di                             // disable for now...
	ehb
// interrupts may be enabled now, then we put EIC IRQ # read as 'critical' reg
	.irp    reg, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, \
		    17, 18, 19, 20, 21, 22, 23, 24, 25, 31
	sw      $\reg, PTR_GPR + \reg * 4 (fp)
	.endr
10:
	ehb

	mflo    t2
	mfhi    t3
	sw      t2, PTR_LO(fp)
	sw      t3, PTR_HI(fp)

	addiu   a0, fp, 0
	lui     ra, %hi(IRQ_nonexc_exit)
	j       do_EXC
	 addiu  ra, %lo(IRQ_nonexc_exit)

	.set    pop

	.globl  absent_vm_tlbtree
absent_vm_tlbtree:
// 0-512MB
	.word   0
	.word   0
	.word   0
	.word   0

// 512MB-1GB
	.word   0
	.word   0
	.word   0
	.word   0

// 1GB-1.5GB
	.word   0
	.word   0
	.word   0
	.word   0

// 1.5GB-2GB
	.word   0
	.word   0
	.word   0
	.word   0

// 2GB-2.5GB
	.word   0
	.word   0
	.word   0
	.word   0

// 2.5GB-3GB
	.word   0
	.word   0
	.word   0
	.word   0

// 3GB-3.5GB
	.word   0
	.word   0
	.word   0
	.word   0

// 3.5GB-4GB
	.word   0
	.word   0
	.word   0
	.word   0

.type _save_fpu_regs, @function
.globl  _save_fpu_regs
_save_fpu_regs:
	.set push
	.set noat
	.set hardfloat
	.set noreorder
	mfc0    at, CP0_STATUS
	lui     t0, %hi(CP0_STATUS_CU1|CP0_STATUS_FR)
	or      at, at, t0
	mtc0    at, CP0_STATUS
	ehb
	.irp    reg, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, \
		    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
	sdc1    $\reg, PTR_FPR + \reg * 8 (v0)
	.endr
	cfc1    at, $31
	jr      ra
	  sw    at, PTR_FCR31(v0)
	.set pop

.type _restore_fpu_regs, @function
.globl  _restore_fpu_regs
_restore_fpu_regs:
	.set push
	.set noat
	.set hardfloat
	.set noreorder
	mfc0    at, CP0_STATUS
	lui     t0, %hi(CP0_STATUS_CU1|CP0_STATUS_FR)
	or      at, at, t0
	mtc0    at, CP0_STATUS
	ehb
	lw      at, PTR_FCR31(fp)
	ctc1    at, $31
	.irp    reg, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, \
		    17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31
	ldc1    $\reg, PTR_FPR + \reg * 8 (fp)
	.endr
	jr      ra
	  nop
	.set    pop

.type _save_dsp_regs, @function
.globl  _save_dsp_regs
_save_dsp_regs:
	.set push
	.set noat
	.set dsp
	.set noreorder
	mfc0    at, CP0_STATUS
	xori    t0, $0, 1
	ins     at, t0, CP0_STATUS_MX_SHIFT, 1
	mtc0    at, CP0_STATUS
	ehb
	.irp    reg, 1, 2, 3
	mfhi    at, $ac\reg
	sw      at, PTR_FCR31 + \reg * 8 (v0)
	mflo    at, $ac\reg
	sw      at, PTR_FCR31 + 4 + \reg * 8 (v0)
	.endr
	rddsp   at, 0x3f
	jr      ra
	  sw    at, PTR_FCR31 + 4 (v0)
	.set    pop

.type _restore_dsp_regs, @function
.globl  _restore_dsp_regs
_restore_dsp_regs:
	.set push
	.set noat
	.set dsp
	.set noreorder
	mfc0    at, CP0_STATUS
	xori    t0, $0, 1
	ins     at, t0, CP0_STATUS_MX_SHIFT, 1
	mtc0    at, CP0_STATUS
	ehb
	.irp    reg, 1, 2, 3
	lw      at, PTR_FCR31 + \reg * 8 (fp)
	mthi    at, $ac\reg
	lw      at, PTR_FCR31 + 4 + \reg * 8 (fp)
	mtlo    at, $ac\reg
	.endr
	lw    at, PTR_FCR31 + 4 (fp)
	jr      ra
	  wrdsp   at, 0x3f
	.set    pop

//  Clear guest LLbit in M5150 via excurse into VMID_ERET(7) to do ERET there
//  Requires a page for KSEG0 in VMID_ERET
.type _clear_g_ll, @function
.globl  _clear_g_ll
_clear_g_ll:
	.set push
	.set noat
	.set noreorder
	// setup VMID_ERET and ERET to G.ERET+exception
	di      k0  // CP0_STATUS
	ehb
	ori     k0, CP0_STATUS_EXL
	mtc0    k0, CP0_STATUS      // CP0 Status changed bits: EXL,IE
	ehb

	mtgc0   $0, CP0_STATUS      // predefined good value
	mtgc0   $0, CP0_CAUSE       // predefined good value

	li      k0, VMID_ERET
	mtc0    k0, CP0_GUESTCTL1   // set VMID for

	li      k1, CP0_GUESTCTL0EXT_INIT
	mtc0    k1, CP0_GUESTCTL0EXT    // FCD=1 to prevent tracking

	li  k0, CP0_GUESTCTL0_INIT | (1 << CP0_GUESTCTL0_GM_SHIFT)
	mtc0    k0, CP0_GUESTCTL0

	mtc0    $0, CP0_CONTEXT

	lw      k1, eret_start_addr
	mtc0    k1, CP0_EPC
	addiu   k1, 4   // eret_cont  - TLB_refill + eret_page
	mtgc0   k1, CP0_EPC
	ehb
	// skip SRSctl setup - no GPR use, any value is OK
eret_start:
	eret    // ... double use: root exit and VMID_ERET return to next inst
eret_cont:
	hypcall // VMID_ERET only: trigger exception to return into root
	// after EXC_nonexc_ jumps here - return
_clear_g_ll_cont:
	// mfc0    k1, CP0_GUESTCTL0    -- it is already here
	ins     k1, $0, CP0_GUESTCTL0_GM_SHIFT, 1
	mtc0    k1, CP0_GUESTCTL0   // clear guest flag
	mfc0    k0, CP0_STATUS      // get status with CU0/kernel mode/flags/masks
	ori     k0, CP0_STATUS_IE | CP0_STATUS_EXL
	xori    k0, CP0_STATUS_IE | CP0_STATUS_EXL // clear EXL,IE
	jr.hb   ra
	 mtc0   k1, CP0_STATUS  // and disable IE, enable CU0, kernel mode, no EXL

eret_start_addr:    .word   eret_start - TLB_refill + eret_page
	.set pop


// ==============================================

.type wait, @function
	.globl  wait

	.set push
	.set noreorder
	.set noat
wait:
	addiu   sp, -(6 * 4)
	sw      ra, 16(sp)
	addiu   v0, $0, -1
	mfc0    a0, CP0_CONTEXT
	ins     a0, v0, 31, 1
	mtc0    a0, CP0_CONTEXT
1:
	di
	ehb
	lw      a0, reschedule_flag
	bnez    a0, 2f
	 sw     sp, %gp_rel(irq_sp)(gp)
	syscall 0xf0000
	wait
	ei
	b       1b
	 ehb
2:
	lui     at, %hi(reschedule_flag)
	sw      $0, %lo(reschedule_flag)(at)
	mfc0    a0, CP0_CONTEXT
	ins     a0, $0, 31, 1
	mtc0    a0, CP0_CONTEXT
	lw      ra, 16(sp)
	lui     at, %hi(need_time_update)
	sw      ra, %lo(need_time_update)(at)
	addiu   sp, 6 * 4
	jr.hb   ra
	 ei

	.set pop

// ==============================================

.type __start, @function
// .org    BOOTOFFSET + 0x1000
.globl __start
__start:
.set push
.set noreorder
	mfc0  $4, CP0_STATUS
	li    $8, 0x04000000
	mtc0  $8, CP0_STATUS
	mfc0  $5, CP0_CAUSE
	mtc0  $0, CP0_CAUSE
	move  a2, gp
	move  a3, sp
	ehb

	// clear VTLB
	li    $8, 0x1ffff800     // li   t0, 0x1ffff800
	mtc0  $8, $5, 0          // mtc0 t0, c0_pagemask (256MB)
	li    $8, 0x0000001F     // even page @0MB, cached, dirty, valid, global
	mtc0  $8, $2, 0          // mtc0 t0, c0_entrylo0
	li    $8, 0x0080001F     // odd page @256MB, cached, dirty, valid, global
	mtc0  $8, $3, 0          // mtc0 t0, c0_entrylo1
	li    $8, 0x00000400  // EHINV
	mtc0  $8, $10, 0      // mtc0 t0, c0_entryhi
	li    $9, 63
	mfc0  $8, $16, 1        // Config1
	move  $9, $0
	ext   $9, $8, 25, 6     // extract MMU Size
1:
	mtc0  $9, $0, 0       // mtc0 t0, c0_index
	ehb
	tlbwi
	ehb
	addiu $9, $9, -1
	bgez  $9, 1b
	 nop

//
//  Start board specific initialization
//
	jal     _board_init
	 nop

	// copy data secion
	la    $8, data_section
	la    $9, _fdata
	la    $10, _edata
1:
	subu  $11, $10, $9
	blez  $11, 2f
	 nop
	lw    $12, 0($8)
	sw    $12, 0($9)
	addiu $9, 4
	b     1b
	 addiu $8, 4
2:
	// clear BSS section
	la    $10, _end
3:
	subu  $11, $10, $9
	blez  $11, 4f
	 nop
	sw    $0, 0($9)
	b     3b
	 addiu $9, 4
4:
//        lui   $12, %hi(0xD8000000) // set 1K pages in PageGrain
	lui   $12, %hi(0xC8000000)  // set 4K pages in PageGrain
	mtc0  $12, $5, 1
	mtc0  $0, CP0_CONTEXT       // clear "Idle" flag
	mtc0  $0, $14, 2            // clear Nested EPC
	mtc0  $0, $13, 5            // clear Nested EXC
	ehb
	la    gp, _gp
	la    sp, vzstack
	lw    $11, vzstack_size_total
	add   sp, $11
	addiu sp, - 6 * 4
	addiu fp, sp,  6 * 4 - VZSTACKSIZE
	sw    fp, vm0_thread        // save VM0 frame as a base
	mtc0  fp, CP0_KSCR0

	la    $25, __main
	jr    $25
	 nop
.set pop

.type loop, @function
.globl loop
loop:
1:  b   1b
     nop
