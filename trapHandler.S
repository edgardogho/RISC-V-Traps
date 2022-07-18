//This trap handler will emulate a misaligned LW or C.LW
//instruction. Works by accesing the offending instruction
//pointed by mepc register, figuring out if its LW or C.LW,
//obtaining the destination register (decoding instruction),
//then the offending misaligned address (from mtval register).
//Depending on the misalignment type it will access memory
//to produce the required word and will save it on the destination
//register that produced the trap.

//It will return all CPU registers to their respective values
//when trap is caught, except for the case where destination
//register is sp. In this case it will scratch T5. This can be
//replaced on the saveX2 label for a scratchpad memory address.

//(c) 2022 Edgardo Gho

.section .text.mytrap
.global misalignedTrap
.align 2

misalignedTrap:
    //Advance stack pointer creating room to save
    //CPU register state before using them.
    addi    sp,sp,-24
    //Save temp regs
    sw      s10,20(sp)
    sw      s11,16(sp)
    sw      t3, 12(sp)
    sw      t4, 8(sp)
    sw      t5, 4(sp)
    sw      t6, 0(sp)
    // Read Cause to t3
    csrr    t3,mcause
    //If mcause == 0x04 its a load alignment issue
    addi    t3,t3,-4
    bne     t3,x0,ret //if not 0x04, its not load alignment
    // Read mepc to t3
    csrr    t3,mepc
    // Store next PC address (assumed 4 bytes) in s10 for
    // future mret.
    addi    s10,t3,4
    //At this point, the offending load could be
    //a LW or C.LW. Need to figure out if its
    //16 bit aligned or 32 bit aligned.
    andi    t4,t3,0x3 //Save last 2 bits
    //If ends in 00 it is aligned.
    beq     t4,x0,instaligned
    //else need to mask last 2 bits and read.
    li      t4,0xFFFFFFFC
    and     t3,t4,t3 //t3 has inst address
    //Load and right align the instruction into T3
    lw      t3,0(t3)
    srli    t3,t3,16 //Right aligned
    beq     x0,x0,parseinst

//T3 points to instruction
instaligned:
    lw      t3,0(t3)

//T3 has instruction
parseinst:
    //A full 32 bit LW is imm[11:0] rs1 010 rd 0000011
    //xxxx xxxx xxxx yyyy y010 zzzz z000 0011
    //0000 0000 0000 0000 0010 0000 0000 0011
    //0x00002003
    li      t4,0x00002003
    and     t5,t4,t3 //t4 AND instruction
    beq     t5,t4,reg32lw

    //If not LW, then might be C.LW
    //C.LW is func3 imm rs1' imm rd' op
    //010 xxx yyy xx zzz 00
    //010x xxyy yxxz zz00
    //0100 0000 0000 0000 =  0x4000
    li     t4,0x4000
    and    t5,t3,t4
    beq    t5,t4,comp32lw
    //If not LW or C.LW, return
    beq    x0,x0,ret

//Instruction is LW
//need to figure out the register that will store the value
reg32lw:
    //LW is imm[11:0] rs1 010 rd 0000011
    //So: 0000 0000 0000 0000 0000 xxxx x000 0000
    li     t4,0x00000F80
    and    t4,t4,t3
    srli   t4,t4,7
    beq    x0,x0,completeload
    //T4 now has register index.

//Instruction is C.LW
//need to figure out the register that will store the value
comp32lw:
    //Since its a C.LW, next instruction is not
    //4 bytes away but 2, so subtract 2 from s10
    //which holds the next PC value for mret.
    addi    s10,s10,-2
    //Compress instructions only support
    //registers s0~s1 , a0~a5
    //So need to convert that to 5 bits, but
    //s0=x8 (1000) and encodes as 000 compressed
    //so its simply adding on 1 bit
    li    t4,0x0000001C
    and   t4,t4,t3
    srli  t4,t4,2
    ori   t4,t4,0x8

completeload:
    //s10 holds the return address
    //we can save it on the mepc for mret.
    csrrw   s10,mepc,s10
    //Now T4 has the register (00000 ~ 11111)
    //Need to read the address that failed
    csrr    t3,mtval
    //This could be misaligned by 1,2 or 3 bytes
    addi    t5,x0,3
    and     t6,t5,t3
    beq     t6,t5,misal3
    addi    t5,x0,2
    and     t6,t5,t3
    beq     t6,t5,misal2

//Misaligned by 1 byte.
misal1:
    //Remove last 2 bits from address
    li      s11,0xFFFFFFFC
    and     t3,t3,s11
    //Load 2 words (Address and Address+1)
    lw      t5,0(t3)
    lw      t6,4(t3)
    //Create an 8 bit mask
    addi    s11,x0,0xFF
    //Mask the lower 8 bits of Address+1
    and     t6,t6,s11
    //Shift byte to left (higher byte)
    slli    t6,t6,24
    //Invert the mask to get lower bytes
    xori    s11,s11,-1
    //Mask the lower 24 bits of Address
    and     t5,t5,s11
    //Shift bytes to right (lower 3 bytes)
    srli    t5,t5,8
    //Combine higher byte with lower 3 bytes
    or      t5,t6,t5
    //Jump to save register value.
    beq     x0,x0,savereg

//Misaligned by 2 bytes.
misal2:
    //This follows same logic as misal1 except
    //it uses different masks and shifts.
    li      s11,0xFFFFFFFC
    and     t3,t3,s11
    lw      t5,0(t3)
    lw      t6,4(t3)
    addi    s11,x0,0xFF
    slli    s11,s11,8
    addi    s11,s11,0xFF
    and     t6,t6,s11
    slli    t6,t6,16
    xori    s11,s11,-1
    and     t5,t5,s11
    srli    t5,t5,16
    or      t5,t5,t6
    beq     x0,x0,savereg

//Misaligned by 3 bytes
misal3:
    //This follows same logic as misal1 except
    //it uses different masks and shifts.
    li      s11,0xFFFFFFFC
    and     t3,t3,s11
    lw      t5,0(t3)
    lw      t6,4(t3)
    addi    s11,x0,0xFF
    slli    s11,s11,24
    and     t5,t5,s11
    srli    t5,t5,24
    xori    s11,s11,-1
    and     t6,t6,s11
    slli    t6,t6,8
    or      t5,t5,t6


savereg:
//Some registers are no longer needed...
//Restore them from stack
    lw      s10,20(sp)
    lw      s11,16(sp)
    lw      t3, 12(sp)
//Now T4 has the register
//and T5 has the value to store..
//If register number is less than 26 (s10),
//we can update register, restore stack
//and be on our merry way.

//If it was going to be saved on x0...
//then just return
    beq     t4,x0,unstack
//Increase t6 from 1 to 30
//to match expected register.
    addi    t6,x0,1
    beq     t6,t4,saveX1
    addi    t6,t6,1
    beq     t6,t4,saveX2
    addi    t6,t6,1
    beq     t6,t4,saveX3
    addi    t6,t6,1
    beq     t6,t4,saveX4
    addi    t6,t6,1
    beq     t6,t4,saveX5
    addi    t6,t6,1
    beq     t6,t4,saveX6
    addi    t6,t6,1
    beq     t6,t4,saveX7
    addi    t6,t6,1
    beq     t6,t4,saveX8
    addi    t6,t6,1
    beq     t6,t4,saveX9
    addi    t6,t6,1
    beq     t6,t4,saveX10
    addi    t6,t6,1
    beq     t6,t4,saveX11
    addi    t6,t6,1
    beq     t6,t4,saveX12
    addi    t6,t6,1
    beq     t6,t4,saveX13
    addi    t6,t6,1
    beq     t6,t4,saveX14
    addi    t6,t6,1
    beq     t6,t4,saveX15
    addi    t6,t6,1
    beq     t6,t4,saveX16
    addi    t6,t6,1
    beq     t6,t4,saveX17
    addi    t6,t6,1
    beq     t6,t4,saveX18
    addi    t6,t6,1
    beq     t6,t4,saveX19
    addi    t6,t6,1
    beq     t6,t4,saveX20
    addi    t6,t6,1
    beq     t6,t4,saveX21
    addi    t6,t6,1
    beq     t6,t4,saveX22
    addi    t6,t6,1
    beq     t6,t4,saveX23
    addi    t6,t6,1
    beq     t6,t4,saveX24
    addi    t6,t6,1
    beq     t6,t4,saveX25
    addi    t6,t6,1
    beq     t6,t4,saveX26
    addi    t6,t6,1
    beq     t6,t4,saveX27
    addi    t6,t6,1
    beq     t6,t4,saveX28
//Here it means it has to be restored on a used register
//so need to handle special cases for t4, t5 and t6.
//t4 now holds register (00000~11111)
//t5 has value to store
//t6 is a counter used to match register (00000~11111)
    addi    t6,t6,1
    beq     t6,t4,saveT4
    addi    t6,t6,1
    beq     t6,t4,saveT5
//in this case, t5 has the value but needs to copy
//it to t6 first...
    addi    t6,t5,0 //cp t5 to t6
    lw      t4, 8(sp)
    lw      t5, 4(sp)
    mret //Can finish here


saveT4:
//In this case, t4 has the register and needs to store
//the actual value (which is on T5)
    addi    t4,t5,0 //cp t5 to t4
    beq     x0,x0,savedt4

saveT5:
//In this case, t5 has the value and needs to keep it
//so restore t4
    lw      t4, 8(sp)
    beq     x0,x0,savedt5

saveX1:
    addi    x1,t5,0
    beq     x0,x0,unstack
saveX2:
    //Special one since it restores on the SP
    //and we have been using the SP, so need to restore
    //from the PC first everything we put in there except t5
    //which has the actual value
    lw      t4, 8(sp)
    lw      t6, 0(sp)
    addi    x2,t5,0
    //t5 is now dirty but lost the sp
    //since there is no way to save it
    mret

saveX3:
    addi    x3,t5,0
    beq     x0,x0,unstack
saveX4:
    addi    x4,t5,0
    beq     x0,x0,unstack
saveX5:
    addi    x5,t5,0
    beq     x0,x0,unstack
saveX6:
    addi    x6,t5,0
    beq     x0,x0,unstack
saveX7:
    addi    x7,t5,0
    beq     x0,x0,unstack
saveX8:
    addi    x8,t5,0
    beq     x0,x0,unstack
saveX9:
    addi    x9,t5,0
    beq     x0,x0,unstack
saveX10:
    addi    x10,t5,0
    beq     x0,x0,unstack
saveX11:
    addi    x11,t5,0
    beq     x0,x0,unstack
saveX12:
    addi    x12,t5,0
    beq     x0,x0,unstack
saveX13:
    addi    x13,t5,0
    beq     x0,x0,unstack
saveX14:
    addi    x14,t5,0
    beq     x0,x0,unstack
saveX15:
    addi    x15,t5,0
    beq     x0,x0,unstack
saveX16:
    addi    x16,t5,0
    beq     x0,x0,unstack
saveX17:
    addi    x17,t5,0
    beq     x0,x0,unstack
saveX18:
    addi    x18,t5,0
    beq     x0,x0,unstack
saveX19:
    addi    x19,t5,0
    beq     x0,x0,unstack
saveX20:
    addi    x20,t5,0
    beq     x0,x0,unstack
saveX21:
    addi    x21,t5,0
    beq     x0,x0,unstack
saveX22:
    addi    x22,t5,0
    beq     x0,x0,unstack
saveX23:
    addi    x23,t5,0
    beq     x0,x0,unstack
saveX24:
    addi    x24,t5,0
    beq     x0,x0,unstack
saveX25:
    addi    x25,t5,0
    beq     x0,x0,unstack
saveX26:
    addi    x26,t5,0
    beq     x0,x0,unstack
saveX27:
    addi    x27,t5,0
    beq     x0,x0,unstack
saveX28:
    addi    x28,t5,0
    beq     x0,x0,unstack

unstack:
    lw      t4, 8(sp)
savedt4:
    lw      t5, 4(sp)
savedt5:
    lw      t6, 0(sp)
    addi    sp,sp,20
//mepc should have return address
//So simply call mret to return
//from trap
ret:
    mret
