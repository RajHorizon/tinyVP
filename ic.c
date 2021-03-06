/*
 * Copyright (c) 2016 Leonid Yegoshin
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

/*
 *      PIC32MZEF IC (Interrupt Controler) support and emulation
 *
 *      Support of both - a real (physical) IC and guest's virtual view.
 *      Guest has no a direct access to IC registers.
 *      Each guest thread has a functional copy of IC registers in vmic
 *      and guest access is emulated
 */

#include    "mips.h"
#include    "irq.h"
#include    "ic.h"
#include    "uart.h"
#include    "thread.h"

#include    "mipsasm.h"
#include    <asm/inst.h>

//  Read a current thread (actually guest) virtual interrupt controller
//  register at offset 'off'.
//  Only legitimate offsets are used - each 16 bytes
//
inline unsigned int read_vmic(unsigned long off)
{
	return current->vmdev.vmic.w4[off/16];
}

//  Read a thread (actually guest) virtual interrupt controller
//  register at offset 'off'.
//  Only legitimate offsets are used - each 16 bytes
//
inline unsigned int read_thread_vmic(struct thread *thread, unsigned long off)
{
	return thread->vmdev.vmic.w4[off/16];
}

//  Get virtual IRQ IPL value from virtual interrupt controller
//  IC register 'IPC' is used for appropriate IRQ
//
unsigned int get_vmic_ipl(unsigned int irq)
{
	unsigned int word;
	unsigned int ipc_mask;
	unsigned int ipc;
	int bit_shift;

	word = (current->vmdev.vmic.w4[(irq/4) + (IC_IPC_BASE_OFFSET/16)]);
	bit_shift = (irq % 4) * 8;
	ipc_mask = 0x1F << (bit_shift);
	ipc = (word & ipc_mask) >> (bit_shift + 2);
	return ipc;
}

//  Write to a current thread (actually guest) virtual interrupt controller
//  register at offset 'off'.
//  Only legitimate offsets are used - each 16 bytes
//
inline void write_vmic(unsigned long off, unsigned int val)
{
	current->vmdev.vmic.w4[off/16] = val;
}

//  Write to a thread (actually guest) virtual interrupt controller
//  register at offset 'off'.
//  Only legitimate offsets are used - each 16 bytes
//
inline void write_thread_vmic(struct thread *thread, unsigned long off, unsigned int val)
{
	thread->vmdev.vmic.w4[off/16] = val;
}

//  Read IRQ 'offset' value from a current thread (actually guest) virtual
//  interrupt controller via IC register offset.
//  IC register 'OFF' is used to keep IRQ offset.
//  Special function is due to non-standard offset rules for this register in IC
//
inline unsigned int read_vmic_off(unsigned long off)
{
	return current->vmdev.vmic.off[(off - IC_OFF_BASE_OFFSET)/4];
}

//  Read IRQ 'offset' value from a some thread (actually guest) virtual
//  interrupt controller via IC register offset.
//  IC register 'OFF' is used to keep IRQ offset.
//  Special function is due to non-standard offset rules for this register in IC
//
inline unsigned int read_thread_vmic_off(struct thread *thread, unsigned long off)
{
	return thread->vmdev.vmic.off[(off - IC_OFF_BASE_OFFSET)/4];
}

//  Get IRQ 'offset' value from a some thread (actually guest) virtual IC.
//  IC register 'OFF' is used to keep IRQ offset.
//  Register is calculated via IRQ number.
//
inline unsigned int get_thread_irq2off(struct thread *thread, unsigned int irq)
{
	return  read_thread_vmic_off(thread, IC_OFF_BASE_OFFSET + (irq * 4));
}

//  Write IRQ 'offset' value to a current thread (actually guest) virtual IC
//  via IC register offset.
//  IC register 'OFF' is used to keep IRQ offset.
//  Special function is due to non-standard offset rules for this register in IC
//
inline void write_vmic_off(unsigned long off, unsigned int val)
{
	current->vmdev.vmic.off[(off - IC_OFF_BASE_OFFSET)/4] = val;
}

//  Init virtual IC by zeros
//
void    init_vmic(struct thread *thread)
{
	int i;

	for( i=0; i<74; i++)
		thread->vmdev.vmic.w4[i] = 0;
	for( i=0; i<214; i++)
		thread->vmdev.vmic.off[i] = 0;
}

//  Get thread value of IPC register for IRQ from thread virtual IC
//
inline unsigned int get_thread_vmic_ipc(struct thread *thread, unsigned int irq)
{
	unsigned long offset;
	unsigned int shift;
	unsigned int word;

	offset = IC_IPC_BASE_OFFSET + ((irq/4)*16);
	shift = (irq & 0x3) * 8;
	word = read_thread_vmic(thread, offset);
	return (word >> shift) & 0xff;
}

//  Set virtual IC timer IRQ to 'ON' for thread
//
inline void set_thread_timer_irq(struct thread *thread)
{
	thread->vmdev.vmic.w4[((IC_CP0_TIMER_WORD_NUMBER*16) + IC_IFS_BASE_OFFSET)/16] |= IC_CP0_TIMER_MASK;
}

//  Get thread virtual IC timer IRQ mask
//
inline unsigned int get_thread_timer_mask(struct thread *thread)
{
	return read_thread_vmic(thread, (IC_IEC_BASE_OFFSET + (IC_CP0_TIMER_WORD_NUMBER * 16))) & IC_CP0_TIMER_MASK;
}

//  Get thread virtual IC timer IPL
//
inline unsigned int get_thread_timer_ipl(struct thread *thread)
{
	return (get_thread_vmic_ipc(thread, IC_TIMER_IRQ) >> 2);
}

//  Clear a current thread virtual IC timer IRQ
//
void clear_timer_irq()
{
	current->vmdev.vmic.w4[((IC_CP0_TIMER_WORD_NUMBER*16) + IC_IFS_BASE_OFFSET)/16] &= ~IC_CP0_TIMER_MASK;
}

//  Read a current thread timer IRQ offset from register 'OFF' of virtual IC
//
inline unsigned int read_timer_voff(void)
{
	return read_vmic_off(IC_OFF_BASE_OFFSET + (IC_TIMER_IRQ * 4));
}

//  Mask a real IRQ in IC
//
void    irq_mask(unsigned irq)
{
	volatile unsigned int *iec;
	unsigned int iec_mask;

	iec = ic_iec(irq, &iec_mask);
	*(iec + IC_CLR_WOFFSET) = iec_mask;
}

//  End IRQ in IC procedure
//
//  Guest writes to IFS or IEC, so some emulation is needed.
//  0.  Determine which interrupts should be processed - which bits are changed
//      Take into account IRQ ownership!
//      Take into account virtual vs real IRQ!
//      Take into account that one world write has 32 IRQs!
//  1.  If an injected IRQ is masked - cancel an injection
//  2.  If IFS bits are cleared and IRQ is not pure virtual - copy virtual IEC
//      to real IEC bits, restoring real IEC for next interrupt. At interrupt
//      injection the real IRQ was masked (IEC <= 0) to prevent a next IRQ.
//
void    ic_end_irq(struct exception_frame *exfr, unsigned long va,
		   unsigned int mask, unsigned int emulator_flag,
		   unsigned long value)
{
	volatile unsigned int *iec;
	volatile unsigned int *iecprobe;
	unsigned int bitmask;
	unsigned int emul_bitmask;
	unsigned int mask2;
	unsigned long vareg;

	vareg = va & ~IC_CSI_MASK;
	// setup mask of CLEARING bits (value is already masked for allowed IRQs)
	switch (va & IC_CSI_MASK) {
	case 0:
		// just write
		bitmask = mask & ~value;
		emul_bitmask = emulator_flag & ~value;
		break;
	case IC_CLR_OFFSET:
		// CLR
		bitmask = mask & value;
		emul_bitmask = emulator_flag & value;
		break;
	case IC_SET_OFFSET:
		// SET
		return;
	case IC_INV_OFFSET:
		// INV
		bitmask = mask &
			  ~(value ^
			    (current->vmdev.vmic.w4[(vareg - IC_BASE)/16] |
			    *KSEG1(vareg)));
		emul_bitmask = emulator_flag &
			  ~(value ^
			    (current->vmdev.vmic.w4[(vareg - IC_BASE)/16]));
		break;
	default:
		panic_thread(exfr, "IC: 2: Invalid thread IFS/IEC/IPC access type");
	}

	iec = KSEG1(vareg);
	if (vareg < IC_IEC_BASE)
		iec = KSEG1(vareg + (IC_IEC_BASE_OFFSET - IC_IFS_BASE_OFFSET));

	if (vareg < IC_IEC_BASE) {
		// copy vIEC into rIEC for cleared IFS bits
		*iec = (*iec & ~bitmask) |
		       (current->vmdev.vmic.w4[(iec - IC_PTR)/4] & bitmask);
	}

	// cancel an injected IRQ and try to inject the next one
	if (current->injected_irq >= 0) {
		iecprobe = ic_iec(current->injected_irq, &mask2);
		if ((iecprobe == iec) && ((bitmask|emul_bitmask) & mask2)) {
			cancel_inject_IRQ(exfr);
		}
	}
}

//  Unmask a real IRQ in IC (IEC <= 1)
//
void    irq_unmask(unsigned irq)
{
	volatile unsigned int *iec;
	unsigned int iec_mask;

	iec = ic_iec(irq, &iec_mask);
	*(iec + IC_SET_WOFFSET) = iec_mask;
}

//  Ack real IRQ in IC - clear IFS bit
//
void    irq_ack(unsigned irq)
{
	volatile unsigned int *ifs;
	unsigned int ifs_mask;

	ifs = ic_ifs(irq, &ifs_mask);
	*(ifs + IC_CLR_WOFFSET) = ifs_mask;
}

//  Ack and mask  real IRQ in IC
//
void    irq_mask_and_ack(unsigned irq)
{
	volatile unsigned int *iec;
	unsigned int iec_mask;
	volatile unsigned int *ifs;
	unsigned int ifs_mask;

	iec = ic_iec(irq, &iec_mask);
	*(iec + IC_CLR_WOFFSET) = iec_mask;

	ifs = ic_ifs(irq, &ifs_mask);
	*(ifs + IC_CLR_WOFFSET) = ifs_mask;
}

//  Set a real IRQ priority in IPC and unmask
//
void    irq_set_prio_and_unmask(unsigned int irq, unsigned int prio)
{
	volatile unsigned int *ipc;
	unsigned int ipc_mask, bit_shift;

	ipc = ic_ipc(irq, &ipc_mask, &bit_shift);
	*(ipc) &= ~ipc_mask;
	*(ipc) |= ((prio << bit_shift) & ipc_mask);

	irq_unmask(irq);
}

//  Insert IRQ into virtual IC of thread. No attempt to inject it
//
void    insert_sw_irq(unsigned int thread, unsigned int irq)
{
	struct thread *next  = get_thread_fp(thread);
	unsigned long vaoff;
	unsigned int mask;
	unsigned int value;

	/* set IFS bit */
	vaoff = KPHYS(ic_ifs(irq, &mask));
	vaoff -= IC_BASE;
	value = read_thread_vmic(next, vaoff);
	value |= mask;
	write_thread_vmic(next, vaoff, value);
}

//  Try to force IRQ - verify masks&IPLs and insert it in virtual IC
//
void    enforce_irq(struct exception_frame *exfr, unsigned int thread, unsigned int irq)
{
	struct thread *next  = get_thread_fp(thread);
	unsigned long vaoff;
	unsigned int mask;
	unsigned int shift;
	unsigned int value;
	unsigned int cipl;

if (!next->tid)
    return;

if (!next->gid) {
char str[128];
sprintf(str, "enforce_irq: tries a non-guest thread %d\n", thread);
uart_writeline(console_uart, str);
return;
}
	/* check IFS bit */
	vaoff = KPHYS(ic_ifs(irq, &mask));
	vaoff -= IC_BASE;
	value = read_thread_vmic(next, vaoff);
	value &= mask;
	if (!value)
		return;

	/* check IEC bit */
	vaoff += (IC_IEC_BASE - IC_IFS_BASE); // shift to enable masks
	value = read_thread_vmic(next, vaoff);
	value &= mask;
	if (!value)
		return;

	vaoff = KPHYS(ic_ipc(irq, &mask, &shift));
	vaoff -= IC_BASE;
	value = read_thread_vmic(next, vaoff);
	value = (value & mask) >> (shift + 2); // IRQ CPU IPL

	// mask&IPL enables IRQ, insert it into guest
	insert_IRQ(exfr, thread, irq, value);
}

//  Execute a pass-through of a real IRQ down to guest
//
int execute_IRQ(struct exception_frame *exfr, unsigned int irq, unsigned int ipl)
{
	emulator_irq *irq_emulator;
	unsigned int vm;
	unsigned int thread;

	irq_emulator = get_irq2emulator(irq);
	if (irq_emulator) {
		if (emulate_irq(exfr, irq_emulator, irq, ipl))
			return 1;
	}

	thread = get_irq2vm(irq);
	if (thread) {
		irq_mask(irq);
		insert_sw_irq(thread, irq);
		enforce_irq(exfr, thread, irq);
		return 1;
	}
	return 0;
}

//  Main process from IRQ entry
//
//  Process system IRQs and look into guest assigned to execute it
//
void do_IRQ(struct exception_frame *exfr)
{
	unsigned int irq = (*IC_INTSTAT) & IC_INTSTAT_SIRQ_MASK;

unsigned char str[128];

	need_time_update = 1;

	switch (irq) {
	case _TIMER_IRQ:
		/* kill spurious IRQ (_TIMER_IRQ == 0) */
		if (!(read_cp0_cause() & CP0_CAUSE_TI))
			return;
		time_irq(exfr, irq);
		return;

	case _UART1_IRQ_TX:
	case _UART2_IRQ_TX:
	case _UART3_IRQ_TX:
	case _UART4_IRQ_TX:
	case _UART5_IRQ_TX:
	case _UART6_IRQ_TX:
		uart_tx_irq(irq);
		return;

	case _UART1_IRQ_RX:
	case _UART2_IRQ_RX:
	case _UART3_IRQ_RX:
	case _UART4_IRQ_RX:
	case _UART5_IRQ_RX:
	case _UART6_IRQ_RX:
		uart_rx_irq(exfr, irq);
		return;

	case PIC32_IRQ_SB:
		sba_irq();
		return;
	}

	/* check for guest assignment */
	if (execute_IRQ(exfr, irq, get__ipl(read_cp0_viewripl())))
		return;

sprintf(str, "do_IRQ: mask unexpect irq %d\n", irq);
uart_writeline(console_uart, str);
	/* mask unexpect interrupt forever */
	irq_mask(irq);
}

//  Init a real IRQ subsystem
//
void init_IRQ(void)
{
	int i;
	volatile unsigned int *priss;
	volatile unsigned int *ipc;
	unsigned int ipc_mask, bit_shift;
	extern void _ebase();
unsigned char str[128];

	*IC_INTCON = IC_INTCON_INIT;

	priss = IC_PRISS;
sprintf(str, "init_IRQ: priss=0x%08x *priss=0x%08x SRSctl=0x%08x\n", priss,*priss,read_cp0_srsctl());
uart_writeline(console_uart, str);
//        *priss = IC_PRISS_SS0;

	for (i=0; i<IC_INT_NUM; i++) {
		if (!irq_available(i))
			continue;
		irq_mask(i);
	}

	for (i=0; i<IC_INT_NUM; i++) {
		if (!irq_available(i))
			continue;
		ipc = ic_ipc(i, &ipc_mask, &bit_shift);
		*(ipc) |= (0x8 << bit_shift);
	}

	i = set_cp0_status(CP0_STATUS_BEV);
	ehb();
	write_cp0_ebase((unsigned long)_ebase);
	ehb();
	set_cp0_cause(CP0_CAUSE_IV);
	write_cp0_intctl(CP0_INTCTL_INIT);
	ehb();
	set_cp0_status(i);
	ehb();

sprintf(str, "init_IRQ: EBase=0x%08x\n", read_cp0_ebase());
uart_writeline(console_uart, str);
}

//  Emulate 'read IC register' (IFS/IEC/IPC only)
//  Read a real IC register and mix it with virtual IC
unsigned long emulate_read_ic(struct exception_frame *exfr, unsigned long vaoff,
			     unsigned long vareg)
{
	unsigned int emulator_flag;
	unsigned int mask;
	unsigned int value;

#if 0
... removed because it seems that IFS must be cleared for each IRQ
	if ((current->injected_irq >= 0) && (vaoff < IC_IEC_BASE_OFFSET)) {
		// IFS read, release a held IEC if matches, for interruptless G.
		ifs = ic_ifs(current->injected_irq, &mask);
		if ((ifs - IC_PTR) == (vaoff/4)) {
			iec = ifs + (IC_IEC_BASE_OFFSET - IC_IFS_BASE_OFFSET)/4;
			// copy vIEC --> rIEC, enable this IRQ again
			*iec = (*iec & ~mask) |
			       (current->vmdev.vmic.w4[(iec - IC_PTR)/4] & mask);
			// switch to next IRQ
			exc_injected_handler(exfr);
		}
	}
#endif

	mask = get_ic_mask(current->tid, vaoff, &emulator_flag);
	value = *KSEG1(vareg);

	value &= mask;      // mask does NOT have the emulated bits
	value = (value & ~emulator_flag) | read_vmic(vaoff);

	return value;
}

//  Emulate 'write IC register' (IFS/IEC/IPC only)
//
//  1.  Detect WR/CLR/SET/INV offsets and change virtual IC
//  2.  IFS/IEC: End of IRQ
//  3.  Loop through 32 bits and call an assigned device emulator
//
unsigned long emulate_write_ic(struct exception_frame *exfr,
			       unsigned long va, unsigned long vaoff,
			       unsigned long gpr, unsigned int *mask)
{
	int i;
	int irq;
	unsigned int val;
	unsigned int v;
	unsigned int irqw;
	unsigned long ret;
	unsigned int emulator_flag;

	*mask = get_ic_mask(current->tid, vaoff, &emulator_flag);

	ret = gpr & *mask;           // mask does NOT includes the emulated bits

	val = gpr & (emulator_flag | *mask);
	vaoff &= ~IC_CSI_MASK;

	v = read_vmic(vaoff);
	switch (va & IC_CSI_MASK) {
	case 0:
		// just write
		v = val;
		break;
	case IC_CLR_OFFSET:
		// CLR
		v = (v & ~val);
		break;
	case IC_SET_OFFSET:
		// SET
		v = (v | val);
		break;
	case IC_INV_OFFSET:
		// INV
		v = (v ^ val);
		break;
	default:
		panic_thread(exfr, "IC: Invalid thread IFS/IEC/IPC access type");
	}
	write_vmic(vaoff, v);

	if (va < IC_IPC_BASE)
		ic_end_irq(exfr, va, *mask, emulator_flag, gpr);

#if 0
	// accelerate return for CP0 timer IRQ only
	if (emulator_flag == IC_CP0_TIMER_MASK) {
		if (va == IC_IFS_BASE)
			return ret;
		if (va == IC_IEC_BASE) {
			if (v & IC_CP0_TIMER_MASK)
				inject_timer_irq(exfr);
			return ret;
		}
	}
#endif

	// trigger an emulator, it can cancel/setup IRQ
	if ((va >= IC_IFS_BASE) && (va < IC_IPC_BASE)) {
		emulator_ic_write *emulator;

		while ((i=clz(emulator_flag)) < 32) {
			i = 31 - i;
			irqw = 1 << i;
			emulator_flag ^= irqw;
			irq = get_icaddr2irq(vaoff, i);
			emulator = get_irq2emulator_ic_write(irq);
			if (emulator)
				emulate_ic_write(exfr, emulator, irq);
		}
	}
	// no emulator call for IPC write
	return ret;
}

//  Main emulation entry from TLB exception handler
//
int ic_emulator(struct exception_frame *exfr)
{
	unsigned long va, vaoff, vareg;
	unsigned long gpr, value;
	unsigned int mask, rt, opcode;

	va = exfr->cp0_badvaddr;
	rt = GET_INST_RT(exfr->cp0_badinst);
	opcode = GET_INST_OPCODE(exfr->cp0_badinst);
	vaoff = va - IC_BASE;
	vareg = va & ~IC_CSI_MASK;

	switch (vareg) {
	case IC_INTCON_BASE:
	case IC_PRISS_BASE:
	case IC_IPTMR_BASE:
		switch (opcode) {
		case lw_op:
			gpr = read_vmic(vaoff);
			gpr_write(exfr, rt, gpr);
			return 1;
		case sw_op:
			value = read_vmic(vaoff);
			gpr = gpr_read(exfr, rt);
			switch (va & IC_CSI_MASK) {
			case 0:
				// just write
				write_vmic(vaoff, gpr);
				return 1;
			case IC_CLR_OFFSET:
				// CLR
				value = (value & ~gpr);
				write_vmic(vaoff, value);
				return 1;
			case IC_SET_OFFSET:
				// SET
				value = (value | gpr);
				write_vmic(vaoff, value);
				return 1;
			case IC_INV_OFFSET:
				// INV
				value = (value ^ gpr);
				write_vmic(vaoff, value);
				return 1;
			default:
				;
			}
			// fall through
		default:
			panic_thread(exfr, "IC Invalid thread INTCON/PRISS/IPTMR access type");
			return 0;
		}

	case IC_INTSTAT_BASE:
		switch (opcode) {
		case lw_op:
			gpr = (current->interrupted_ipl << IC_INTSTAT_SRIPL_SHIFT) |
				current->interrupted_irq;
			gpr_write(exfr, rt, gpr);
			return 1;
		case sw_op:
			return 1;
		default:
			panic_thread(exfr, "IC Invalid thread INSTAT access type");
			return 0;
		}
	}

	if ((va >= IC_IFS_BASE) && (va < IC_OFF_BASE)) {
		// access to IFS, IEC or IPC
		switch (opcode) {
		case lw_op:
			gpr = emulate_read_ic(exfr, vaoff, vareg);
			gpr_write(exfr, rt, gpr);
			return 1;
		case sw_op:
			gpr = gpr_read(exfr, rt);
			value = *KSEG1(vareg);
			gpr = emulate_write_ic(exfr, va, vaoff, gpr, &mask);
			if (!mask)
				return 1;

			// disallow a highest PRIO for guest
			if ((va >= IC_IPC_BASE) && (va < IC_OFF_BASE)) {
				if ((gpr & IC_IPC_LIMIT_MASK) > IC_IPC_LIMIT)
					gpr = (gpr & ~IC_IPC_LIMIT_MASK) | IC_IPC_LIMIT;
				if ((gpr & (IC_IPC_LIMIT_MASK << 8)) > (IC_IPC_LIMIT << 8))
					gpr = (gpr & ~(IC_IPC_LIMIT_MASK << 8)) | (IC_IPC_LIMIT << 8);
				if ((gpr & (IC_IPC_LIMIT_MASK << 16)) > (IC_IPC_LIMIT << 16))
					gpr = (gpr & ~(IC_IPC_LIMIT_MASK << 16)) | (IC_IPC_LIMIT << 16);
				if ((gpr & (IC_IPC_LIMIT_MASK << 24)) > (IC_IPC_LIMIT << 24))
					gpr = (gpr & ~(IC_IPC_LIMIT_MASK << 24)) | (IC_IPC_LIMIT << 24);
			}

			if (va & IC_CSI_MASK)
				*KSEG1(va) = gpr;
			else
				*KSEG1(va) = gpr | (value & ~mask);

			return 1;
		default:
			panic_thread(exfr, "IC: Invalid thread IFS/IEC/IPC access type");
			return 0;
		}

	} else if ((va >= IC_OFF_BASE) && (va < IC_OFF_END_BASE)) {
		// access to OFF
		switch (opcode) {
		case lw_op:
			gpr = read_vmic_off(vaoff);
			gpr_write(exfr, rt, gpr);
			return 1;
		case sw_op:
			write_vmic_off(vaoff, gpr_read(exfr, rt));
			return 1;
		case sb_op:
			gpr = read_vmic_off(vaoff & ~0x3);
			gpr = gpr & ~(0xff << ((vaoff & 0x3) * 8));       // LE only
			gpr = gpr | ((gpr_read(exfr, rt) & 0xff) << ((vaoff & 0x3) * 8)); // LE only
			write_vmic_off(vaoff, gpr);
			return 1;
		default:
			panic_thread(exfr, "IC: Invalid thread OFF access type");
			return 0;
		}

	} else {
		panic_thread(exfr, "IC: access beyond Interrupt controller\n");
		return 0;
	}
	return 1;
}

// select a highest virtial IRQ IPL from IFS word
//
unsigned int pickup_word_sw_irq(struct exception_frame *exfr,
				unsigned int word, unsigned int irqoff,
				unsigned int *tipl, unsigned int gipl)
{
	int irq0 = -1;
	int ipl0 = -1;
	int ipl;
	int irq;
	int i;
	unsigned int irqw;

	ipl0 = (*tipl > gipl) ? *tipl : gipl;
	while ((i=clz(word)) < 32) {
		i = 31 - i;
		irqw = 1 << i;
		word ^= irqw;

		irq = irqoff + i;

		ipl = get_vmic_ipl(irq);
		if (ipl > ipl0) {
			irq0 = irq;
			ipl0 = ipl;
		}
	}

	if (irq0 >= 0)
		*tipl = ipl0;
	return irq0;
}

// select a highest IRQ by IPL from whole vmic array
//
unsigned int pickup_irq(struct exception_frame *exfr, unsigned int *tipl,
			   unsigned int *voff, unsigned int gipl)
{
	unsigned int *ifsp;
	unsigned int *iecp;
	unsigned int word;
	unsigned int tipl0 = 0;
	int irq0 = -1;
	int irq;

	if (read_g_cp0_cause() & CP0_CAUSE_TI)
		set_thread_timer_irq(current);

	ifsp = &(current->vmdev.vmic.w4[(IC_IFS_BASE_OFFSET)/16]) - 1;
	iecp = &(current->vmdev.vmic.w4[(IC_IEC_BASE_OFFSET)/16]) - 1;
	*tipl = 0;

	/* word 0 */
	if ((word = ((*++ifsp) & (*++iecp)))) {
		irq = pickup_word_sw_irq(exfr, word, 0, tipl, gipl);
		if ((irq >= 0) && (*tipl > tipl0)) {
			tipl0 = *tipl;
			irq0 = irq;
		}
	}
	/* word 1 */
	if ((word = ((*++ifsp) & (*++iecp)))) {
		irq = pickup_word_sw_irq(exfr, word, 32, tipl, gipl);
		if ((irq >= 0) && (*tipl > tipl0)) {
			tipl0 = *tipl;
			irq0 = irq;
		}
	}
	/* word 2 */
	if ((word = ((*++ifsp) & (*++iecp)))) {
		irq = pickup_word_sw_irq(exfr, word, 64, tipl, gipl);
		if ((irq >= 0) && (*tipl > tipl0)) {
			tipl0 = *tipl;
			irq0 = irq;
		}
	}
	/* word 3 */
	if ((word = ((*++ifsp) & (*++iecp)))) {
		irq = pickup_word_sw_irq(exfr, word, 96, tipl, gipl);
		if ((irq >= 0) && (*tipl > tipl0)) {
			tipl0 = *tipl;
			irq0 = irq;
		}
	}
	/* word 4 */
	if ((word = ((*++ifsp) & (*++iecp)))) {
		irq = pickup_word_sw_irq(exfr, word, 128, tipl, gipl);
		if ((irq >= 0) && (*tipl > tipl0)) {
			tipl0 = *tipl;
			irq0 = irq;
		}
	}
	/* word 5 */
	if ((word = ((*++ifsp) & (*++iecp)))) {
		irq = pickup_word_sw_irq(exfr, word, 160, tipl, gipl);
		if ((irq >= 0) && (*tipl > tipl0)) {
			tipl0 = *tipl;
			irq0 = irq;
		}
	}
	/* word 6 */
	if ((word = ((*++ifsp) & (*++iecp)))) {
		irq = pickup_word_sw_irq(exfr, word, 192, tipl, gipl);
		if ((irq >= 0) && (*tipl > tipl0)) {
			tipl0 = *tipl;
			irq0 = irq;
		}
	}

	if (irq0 >= 0) {
		*voff = get_irq2off(irq0);
		return irq0;
	}

	return -1;
}

emulator_ic_write   interrupt_ic;

//  Write to pure virtual IRQ stab
//
unsigned int        interrupt_ic(struct exception_frame *exfr, unsigned int irq)
{
	/* start IRQ in vm ... */
	enforce_irq(exfr, current->tid, irq);
}

extern emulator_irq    interrupt_irq;

//  Stab for pure virtual IRQ. Syntax fix only, no real use.
//
unsigned int    interrupt_irq(struct exception_frame *exfr, unsigned int irq,
			   unsigned int ipl)
{
	return 0;
}

//  Debug printout of IC and virtual IC of current thread
//
void ic_print(struct thread *next)
{
	int i;
	char str[128];

	uart_writeline(console_uart, "\nIFS:\n");
	for (i=0; i<7; i++) {
	    sprintf(str," %08x", *(IC_IFS + (i * 4)));
	    uart_writeline(console_uart, str);
	}
	uart_writeline(console_uart, "\nIEC:\n");
	for (i=0; i<7; i++) {
	    sprintf(str," %08x", *(IC_IEC + (i * 4)));
	    uart_writeline(console_uart, str);
	}
	uart_writeline(console_uart, "\nvmic IFS:\n");
	for (i=0; i<7; i++) {
	    sprintf(str," %08x", read_thread_vmic(next, (IC_IFS_BASE_OFFSET + (i * 16))));
	    uart_writeline(console_uart, str);
	}
	uart_writeline(console_uart, "\nvmic IEC:\n");
	for (i=0; i<7; i++) {
	    sprintf(str," %08x", read_thread_vmic(next, (IC_IEC_BASE_OFFSET + (i * 16))));
	    uart_writeline(console_uart, str);
	}
	uart_writeline(console_uart, "\n");
}
