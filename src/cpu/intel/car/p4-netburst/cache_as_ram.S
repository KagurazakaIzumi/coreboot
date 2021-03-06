/*
 * This file is part of the coreboot project.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; version 2 of the License.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#include <cpu/x86/mtrr.h>
#include <cpu/x86/cache.h>
#include <cpu/x86/post_code.h>
#include <cpu/x86/lapic_def.h>

/* Macro to access Local APIC registers at default base. */
#define LAPIC(x)		$(LAPIC_DEFAULT_BASE | LAPIC_ ## x)

#define CACHE_AS_RAM_SIZE CONFIG_DCACHE_RAM_SIZE
#define CACHE_AS_RAM_BASE CONFIG_DCACHE_RAM_BASE

#if ((CONFIG_C_ENV_BOOTBLOCK_SIZE & (CONFIG_C_ENV_BOOTBLOCK_SIZE - 1)) != 0)
#error "CONFIG_C_ENV_BOOTBLOCK_SIZE must be a power of 2!"
#endif
#define XIP_ROM_SIZE CONFIG_C_ENV_BOOTBLOCK_SIZE

.global bootblock_pre_c_entry

.code32
_cache_as_ram_setup:

bootblock_pre_c_entry:

cache_as_ram:
	post_code(0x20)

	movl	$LAPIC_BASE_MSR, %ecx
	rdmsr
	andl	$LAPIC_BASE_MSR_BOOTSTRAP_PROCESSOR, %eax
	jz	ap_init

	/* Clear/disable fixed MTRRs */
	mov	$fixed_mtrr_list_size, %ebx
	xor	%eax, %eax
	xor	%edx, %edx

clear_fixed_mtrr:
	add	$-2, %ebx
	movzwl	fixed_mtrr_list(%ebx), %ecx
	wrmsr
	jnz	clear_fixed_mtrr

	/* Figure out how many MTRRs we have, and clear them out */
	mov	$MTRR_CAP_MSR, %ecx
	rdmsr
	movzb	%al, %ebx		/* Number of variable MTRRs */
	mov	$MTRR_PHYS_BASE(0), %ecx
	xor	%eax, %eax
	xor	%edx, %edx

clear_var_mtrr:
	wrmsr
	inc	%ecx
	wrmsr
	inc	%ecx
	dec	%ebx
	jnz	clear_var_mtrr
	post_code(0x21)

	/* Configure the default memory type to uncacheable. */
	movl	$MTRR_DEF_TYPE_MSR, %ecx
	rdmsr
	andl	$(~0x00000cff), %eax
	wrmsr

	post_code(0x22)

	/* Determine CPU_ADDR_BITS and load PHYSMASK high
	 * word to %edx.
	 */
	movl	$0x80000000, %eax
	cpuid
	cmpl	$0x80000008, %eax
	jc	addrsize_no_MSR
	movl	$0x80000008, %eax
	cpuid
	movb	%al, %cl
	sub	$32, %cl
	movl	$1, %edx
	shl	%cl, %edx
	subl	$1, %edx
	jmp	addrsize_set_high
addrsize_no_MSR:
	movl	$1, %eax
	cpuid
	andl	$(1 << 6 | 1 << 17), %edx	/* PAE or PSE36 */
	jz	addrsize_set_high
	movl	$0x0f, %edx

	/* Preload high word of address mask (in %edx) for Variable
	 * MTRRs 0 and 1 and enable local APIC at default base.
	 */
addrsize_set_high:
	xorl	%eax, %eax
	movl	$MTRR_PHYS_MASK(0), %ecx
	wrmsr
	movl	$MTRR_PHYS_MASK(1), %ecx
	wrmsr
	movl	$LAPIC_BASE_MSR, %ecx
	not	%edx
	movl	%edx, %ebx
	rdmsr
	andl	%ebx, %edx
	andl	$(~LAPIC_BASE_MSR_ADDR_MASK), %eax
	orl	$(LAPIC_DEFAULT_BASE | LAPIC_BASE_MSR_ENABLE), %eax
	wrmsr

bsp_init:

	post_code(0x23)

	/* Send INIT IPI to all excluding ourself. */
	movl	LAPIC(ICR), %edi
	movl	$(LAPIC_DEST_ALLBUT | LAPIC_INT_ASSERT | LAPIC_DM_INIT), %eax
1:	movl	%eax, (%edi)
	movl	$0x30, %ecx
2:	pause
	dec	%ecx
	jnz	2b
	movl	(%edi), %ecx
	andl	$LAPIC_ICR_BUSY, %ecx
	jnz	1b

	post_code(0x24)

	movl	$1, %eax
	cpuid
	btl	$28, %edx
	jnc	sipi_complete
	bswapl	%ebx
	movzx	%bh, %edi
	cmpb	$1, %bh
	jbe	sipi_complete	/* only one LAPIC ID in package */

	movl	$0, %eax
	cpuid
	movb	$1, %bl
	cmpl	$4, %eax
	jb	cores_counted
	movl	$4, %eax
	movl	$0, %ecx
	cpuid
	shr	$26, %eax
	movb	%al, %bl
	inc	%bl

cores_counted:
	movl	%edi, %eax
	divb	%bl
	cmpb	$1, %al
	jbe	sipi_complete	/* only LAPIC ID of a core */

	/* For a hyper-threading processor, cache must not be disabled
	 * on an AP on the same physical package with the BSP.
	 */

hyper_threading_cpu:

	post_code(0x25)

	/* Send Start IPI to all excluding ourself. */
	movl	LAPIC(ICR), %edi
	movl	$(LAPIC_DEST_ALLBUT | LAPIC_DM_STARTUP), %eax
	orl	$ap_sipi_vector_in_rom, %eax
1:	movl	%eax, (%edi)
	movl	$0x30, %ecx
2:	pause
	dec	%ecx
	jnz	2b
	movl	(%edi), %ecx
	andl	$LAPIC_ICR_BUSY, %ecx
	jnz	1b

	post_code(0x26)

	/* Wait for sibling CPU to start. */
1:	movl	$(MTRR_PHYS_BASE(0)), %ecx
	rdmsr
	andl	%eax, %eax
	jnz	sipi_complete

	movl	$0x30, %ecx
2:	pause
	dec	%ecx
	jnz	2b
	jmp	1b


ap_init:
	post_code(0x27)

	/* Do not disable cache (so BSP can enable it). */
	movl	%cr0, %eax
	andl	$(~(CR0_CacheDisable | CR0_NoWriteThrough)), %eax
	movl	%eax, %cr0

	post_code(0x28)

	/* MTRR registers are shared between HT siblings. */
	movl	$(MTRR_PHYS_BASE(0)), %ecx
	movl	$(1 << 12), %eax
	xorl	%edx, %edx
	wrmsr

	post_code(0x29)

ap_halt:
	cli
1:	hlt
	jmp	1b



sipi_complete:

	post_code(0x2a)

	/* Set Cache-as-RAM base address. */
	movl	$(MTRR_PHYS_BASE(0)), %ecx
	movl	$(CACHE_AS_RAM_BASE | MTRR_TYPE_WRBACK), %eax
	xorl	%edx, %edx
	wrmsr

	/* Set Cache-as-RAM mask. */
	movl	$(MTRR_PHYS_MASK(0)), %ecx
	rdmsr
	movl	$(~(CACHE_AS_RAM_SIZE - 1) | MTRR_PHYS_MASK_VALID), %eax
	wrmsr

	post_code(0x2b)

	/* Enable MTRR. */
	movl	$MTRR_DEF_TYPE_MSR, %ecx
	rdmsr
	orl	$MTRR_DEF_TYPE_EN, %eax
	wrmsr

	/* Enable L2 cache Write-Back (WBINVD and FLUSH#).
	 *
	 * MSR is set when DisplayFamily_DisplayModel is one of:
	 * 06_0x, 06_17, 06_1C
	 *
	 * Description says this bit enables use of WBINVD and FLUSH#.
	 * Should this be set only after the system bus and/or memory
	 * controller can successfully handle write cycles?
	 */

#define EAX_FAMILY(a)	(a << 8)	/* for family <= 0fH */
#define EAX_MODEL(a)	(((a & 0xf0) << 12) | ((a & 0xf) << 4))

	movl	$1, %eax
	cpuid
	movl	%eax, %ebx
	andl	$EAX_FAMILY(0x0f), %eax
	cmpl	$EAX_FAMILY(0x06), %eax
	jne	no_msr_11e
	movl	%ebx, %eax
	andl	$EAX_MODEL(0xff), %eax
	cmpl	$EAX_MODEL(0x17), %eax
	je	has_msr_11e
	cmpl	$EAX_MODEL(0x1c), %eax
	je	has_msr_11e
	andl	$EAX_MODEL(0xf0), %eax
	cmpl	$EAX_MODEL(0x00), %eax
	jne	no_msr_11e
has_msr_11e:
	movl	$0x11e, %ecx
	rdmsr
	orl	$(1 << 8), %eax
	wrmsr
no_msr_11e:

	post_code(0x2c)

	/* Cache the whole rom to fetch microcode updates */
	movl	$MTRR_PHYS_BASE(1), %ecx
	xorl	%edx, %edx
	movl	$(CACHE_ROM_BASE | MTRR_TYPE_WRPROT), %eax
	wrmsr

	movl	$MTRR_PHYS_MASK(1), %ecx
	rdmsr
	movl	$(~(CACHE_ROM_SIZE - 1) | MTRR_PHYS_MASK_VALID), %eax
	wrmsr

	/* Enable cache (CR0.CD = 0, CR0.NW = 0). */
	movl	%cr0, %eax
	andl	$(~(CR0_CacheDisable | CR0_NoWriteThrough)), %eax
	invd
	movl	%eax, %cr0

#if CONFIG(MICROCODE_UPDATE_PRE_RAM)
	update_microcode:
	/* put the return address in %esp */
	movl	$end_microcode_update, %esp
	jmp	update_bsp_microcode
	end_microcode_update:
#endif
	post_code(0x2d)
	/* Disable caching to change MTRR's. */
	movl	%cr0, %eax
	orl	$CR0_CacheDisable, %eax
	movl	%eax, %cr0

	/*
	 * An unidentified combination of speculative reads and branch
	 * predictions inside WRPROT-cacheable memory can cause invalidation
	 * of cachelines and loss of stack on models based on NetBurst
	 * microarchitecture. Therefore disable WRPROT region entirely for
	 * all family F models.
	 */
	movl	$1, %eax
	cpuid
	cmp	$0xf, %ah
	jne	cache_rom

disable_cache_rom:
	movl	$MTRR_PHYS_MASK(1), %ecx
	rdmsr
	andl	$(~MTRR_PHYS_MASK_VALID), %eax
	wrmsr
	jmp	fill_cache

cache_rom:
	/* Enable cache for our code in Flash because we do XIP here */
	movl	$MTRR_PHYS_BASE(1), %ecx
	xorl	%edx, %edx
	/*
	 * IMPORTANT: The following calculation _must_ be done at runtime. See
	 * https://mail.coreboot.org/pipermail/coreboot/2010-October/060922.html
	 */
	movl	$_program, %eax
	andl	$(~(XIP_ROM_SIZE - 1)), %eax
	orl	$MTRR_TYPE_WRPROT, %eax
	wrmsr

	movl	$MTRR_PHYS_MASK(1), %ecx
	rdmsr
	movl	$(~(XIP_ROM_SIZE - 1) | MTRR_PHYS_MASK_VALID), %eax
	wrmsr

fill_cache:
	post_code(0x2e)
	/* Enable cache. */
	movl	%cr0, %eax
	andl	$(~(CR0_CacheDisable | CR0_NoWriteThrough)), %eax
	invd
	movl	%eax, %cr0

	/* Clear the cache memory region. This will also fill up the cache. */
	cld
	xorl	%eax, %eax
	movl	$CACHE_AS_RAM_BASE, %edi
	movl	$(CACHE_AS_RAM_SIZE >> 2), %ecx
	rep	stosl

	/* Setup the stack. */
	mov	$_ecar_stack, %esp

	/* Need to align stack to 16 bytes at call instruction. Account for
	the pushes below. */
	andl	$0xfffffff0, %esp
	subl	$4, %esp

	/* push TSC and BIST to stack */
	movd	%mm0, %eax
	pushl	%eax	/* BIST */
	movd	%mm2, %eax
	pushl	%eax	/* tsc[63:32] */
	movd	%mm1, %eax
	pushl	%eax	/* tsc[31:0] */

before_c_entry:
	post_code(0x2f)
	call	bootblock_c_entry_bist

	/* Should never see this postcode */
	post_code(POST_DEAD_CODE)

.Lhlt:
	hlt
	jmp	.Lhlt

fixed_mtrr_list:
	.word	MTRR_FIX_64K_00000
	.word	MTRR_FIX_16K_80000
	.word	MTRR_FIX_16K_A0000
	.word	MTRR_FIX_4K_C0000
	.word	MTRR_FIX_4K_C8000
	.word	MTRR_FIX_4K_D0000
	.word	MTRR_FIX_4K_D8000
	.word	MTRR_FIX_4K_E0000
	.word	MTRR_FIX_4K_E8000
	.word	MTRR_FIX_4K_F0000
	.word	MTRR_FIX_4K_F8000
fixed_mtrr_list_size = . - fixed_mtrr_list

_cache_as_ram_setup_end:
