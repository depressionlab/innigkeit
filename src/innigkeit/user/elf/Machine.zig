pub const Machine = enum(u16) {
    /// No machine
    NONE = 0,
    /// AT&T WE 32100
    M32 = 1,
    /// SPARC
    SPARC = 2,
    /// Intel 80386
    @"386" = 3,
    /// Motorola 68000
    @"68K" = 4,
    /// Motorola 88000
    @"88K" = 5,
    /// Intel MCU
    IAMCU = 6,
    /// Intel 80860
    @"860" = 7,
    /// MIPS I Architecture
    MIPS = 8,
    /// IBM System/370 Processor
    S370 = 9,
    /// MIPS RS3000 Little-endian
    MIPS_RS3_LE = 10,
    /// Hewlett-Packard PA-RISC
    PARISC = 15,
    /// Fujitsu VPP500
    VPP500 = 17,
    /// Enhanced instruction set SPARC
    SPARC32PLUS = 18,
    /// Intel 80960
    @"960" = 19,
    /// PowerPC
    PPC = 20,
    /// 64-bit PowerPC
    PPC64 = 21,
    /// IBM System/390 Processor
    S390 = 22,
    /// IBM SPU/SPC
    SPU = 23,
    /// NEC V800
    V800 = 36,
    /// Fujitsu FR20
    FR20 = 37,
    /// TRW RH-32
    RH32 = 38,
    /// Motorola RCE
    RCE = 39,
    /// ARM 32-bit architecture (AARCH32)
    ARM = 40,
    /// Digital Alpha
    OLD_ALPHA = 41,
    /// Hitachi SH
    SH = 42,
    /// SPARC Version 9
    SPARCV9 = 43,
    /// Siemens TriCore embedded processor
    TRICORE = 44,
    /// Argonaut RISC Core, Argonaut Technologies Inc.
    ARC = 45,
    /// Hitachi H8/300
    H8_300 = 46,
    /// Hitachi H8/300H
    H8_300H = 47,
    /// Hitachi H8S
    H8S = 48,
    /// Hitachi H8/500
    H8_500 = 49,
    /// Intel IA-64 processor architecture
    IA_64 = 50,
    /// Stanford MIPS-X
    MIPS_X = 51,
    /// Motorola ColdFire
    COLDFIRE = 52,
    /// Motorola M68HC12
    @"68HC12" = 53,
    /// Fujitsu MMA Multimedia Accelerator
    MMA = 54,
    /// Siemens PCP
    PCP = 55,
    /// Sony nCPU embedded RISC processor
    NCPU = 56,
    /// Denso NDR1 microprocessor
    NDR1 = 57,
    /// Motorola Star*Core processor
    STARCORE = 58,
    /// Toyota ME16 processor
    ME16 = 59,
    /// STMicroelectronics ST100 processor
    ST100 = 60,
    /// Advanced Logic Corp. TinyJ embedded processor family
    TINYJ = 61,
    /// AMD x86-64 architecture
    X86_64 = 62,
    /// Sony DSP Processor
    PDSP = 63,
    /// Digital Equipment Corp. PDP-10
    PDP10 = 64,
    /// Digital Equipment Corp. PDP-11
    PDP11 = 65,
    /// Siemens FX66 microcontroller
    FX66 = 66,
    /// STMicroelectronics ST9+ 8/16 bit microcontroller
    ST9PLUS = 67,
    /// STMicroelectronics ST7 8-bit microcontroller
    ST7 = 68,
    /// Motorola MC68HC16 Microcontroller
    @"68HC16" = 69,
    /// Motorola MC68HC11 Microcontroller
    @"68HC11" = 70,
    /// Motorola MC68HC08 Microcontroller
    @"68HC08" = 71,
    /// Motorola MC68HC05 Microcontroller
    @"68HC05" = 72,
    /// Silicon Graphics SVx
    SVX = 73,
    /// STMicroelectronics ST19 8-bit microcontroller
    ST19 = 74,
    /// Digital VAX
    VAX = 75,
    /// Axis Communications 32-bit embedded processor
    CRIS = 76,
    /// Infineon Technologies 32-bit embedded processor
    JAVELIN = 77,
    /// Element 14 64-bit DSP Processor
    FIREPATH = 78,
    /// LSI Logic 16-bit DSP Processor
    ZSP = 79,
    /// Donald Knuth’s educational 64-bit processor
    MMIX = 80,
    /// Harvard University machine-independent object files
    HUANY = 81,
    /// SiTera Prism
    PRISM = 82,
    /// Atmel AVR 8-bit microcontroller
    AVR = 83,
    /// Fujitsu FR30
    FR30 = 84,
    /// Mitsubishi D10V
    D10V = 85,
    /// Mitsubishi D30V
    D30V = 86,
    /// NEC v850
    V850 = 87,
    /// Mitsubishi M32R
    M32R = 88,
    /// Matsushita MN10300
    MN10300 = 89,
    /// Matsushita MN10200
    MN10200 = 90,
    /// picoJava
    PJ = 91,
    /// OpenRISC 32-bit embedded processor
    OPENRISC = 92,
    /// ARC International ARCompact processor (old spelling/synonym: EM_ARC_A5)
    ARC_COMPACT = 93,
    /// Tensilica Xtensa Architecture
    XTENSA = 94,
    /// Alphamosaic VideoCore processor
    VIDEOCORE = 95,
    /// Thompson Multimedia General Purpose Processor
    TMM_GPP = 96,
    /// National Semiconductor 32000 series
    NS32K = 97,
    /// Tenor Network TPC processor
    TPC = 98,
    /// Trebia SNP 1000 processor
    SNP1K = 99,
    /// STMicroelectronics (www.st.com) ST200 microcontroller
    ST200 = 100,
    /// Ubicom IP2xxx microcontroller family
    IP2K = 101,
    /// MAX Processor
    MAX = 102,
    /// National Semiconductor CompactRISC microprocessor
    CR = 103,
    /// Fujitsu F2MC16
    F2MC16 = 104,
    /// Texas Instruments embedded microcontroller msp430
    MSP430 = 105,
    /// Analog Devices Blackfin (DSP) processor
    BLACKFIN = 106,
    /// S1C33 Family of Seiko Epson processors
    SE_C33 = 107,
    /// Sharp embedded microprocessor
    SEP = 108,
    /// Arca RISC Microprocessor
    ARCA = 109,
    /// Microprocessor series from PKU-Unity Ltd. and MPRC of Peking University
    UNICORE = 110,
    /// eXcess: 16/32/64-bit configurable embedded CPU
    EXCESS = 111,
    /// Icera Semiconductor Inc. Deep Execution Processor
    DXP = 112,
    /// Altera Nios II soft-core processor
    ALTERA_NIOS2 = 113,
    /// National Semiconductor CompactRISC CRX microprocessor
    CRX = 114,
    /// Motorola XGATE embedded processor
    XGATE = 115,
    /// Infineon C16x/XC16x processor
    C166 = 116,
    /// Renesas M16C series microprocessors
    M16C = 117,
    /// Microchip Technology dsPIC30F Digital Signal Controller
    DSPIC30F = 118,
    /// Freescale Communication Engine RISC core
    CE = 119,
    /// Renesas M32C series microprocessors
    M32C = 120,
    /// Altium TSK3000 core
    TSK3000 = 131,
    /// Freescale RS08 embedded processor
    RS08 = 132,
    /// Analog Devices SHARC family of 32-bit DSP processors
    SHARC = 133,
    /// Cyan Technology eCOG2 microprocessor
    ECOG2 = 134,
    /// Sunplus S+core7 RISC processor
    SCORE7 = 135,
    /// New Japan Radio (NJR) 24-bit DSP Processor
    DSP24 = 136,
    /// Broadcom VideoCore III processor
    VIDEOCORE3 = 137,
    /// RISC processor for Lattice FPGA architecture
    LATTICEMICO32 = 138,
    /// Seiko Epson C17 family
    SE_C17 = 139,
    /// The Texas Instruments TMS320C6000 DSP family
    TI_C6000 = 140,
    /// The Texas Instruments TMS320C2000 DSP family
    TI_C2000 = 141,
    /// The Texas Instruments TMS320C55x DSP family
    TI_C5500 = 142,
    /// Texas Instruments Application Specific RISC Processor, 32bit fetch
    TI_ARP32 = 143,
    /// Texas Instruments Programmable Realtime Unit
    TI_PRU = 144,
    /// STMicroelectronics 64bit VLIW Data Signal Processor
    MMDSP_PLUS = 160,
    /// Cypress M8C microprocessor
    CYPRESS_M8C = 161,
    /// Renesas R32C series microprocessors
    R32C = 162,
    /// NXP Semiconductors TriMedia architecture family
    TRIMEDIA = 163,
    /// QUALCOMM DSP6 Processor
    QDSP6 = 164,
    /// Intel 8051 and variants
    @"8051" = 165,
    /// STMicroelectronics STxP7x family of configurable and extensible RISC processors
    STXP7X = 166,
    /// Andes Technology compact code size embedded RISC processor family
    NDS32 = 167,
    /// Cyan Technology eCOG1X family
    ECOG1 = 168,
    /// Dallas Semiconductor MAXQ30 Core Micro-controllers
    MAXQ30 = 169,
    /// New Japan Radio (NJR) 16-bit DSP Processor
    XIMO16 = 170,
    /// M2000 Reconfigurable RISC Microprocessor
    MANIK = 171,
    /// Cray Inc. NV2 vector architecture
    CRAYNV2 = 172,
    /// Renesas RX family
    RX = 173,
    /// Imagination Technologies META processor architecture
    METAG = 174,
    /// MCST Elbrus general purpose hardware architecture
    MCST_ELBRUS = 175,
    /// Cyan Technology eCOG16 family
    ECOG16 = 176,
    /// National Semiconductor CompactRISC CR16 16-bit microprocessor
    CR16 = 177,
    /// Freescale Extended Time Processing Unit
    ETPU = 178,
    /// Infineon Technologies SLE9X core
    SLE9X = 179,
    /// Intel L10M
    L10M = 180,
    /// Intel K10M
    K10M = 181,
    /// ARM 64-bit architecture (AARCH64)
    AARCH64 = 183,
    /// Atmel Corporation 32-bit microprocessor family
    AVR32 = 185,
    /// STMicroeletronics STM8 8-bit microcontroller
    STM8 = 186,
    /// Tilera TILE64 multicore architecture family
    TILE64 = 187,
    /// Tilera TILEPro multicore architecture family
    TILEPRO = 188,
    /// Xilinx MicroBlaze 32-bit RISC soft processor core
    MICROBLAZE = 189,
    /// NVIDIA CUDA architecture
    CUDA = 190,
    /// Tilera TILE-Gx multicore architecture family
    TILEGX = 191,
    /// CloudShield architecture family
    CLOUDSHIELD = 192,
    /// KIPO-KAIST Core-A 1st generation processor family
    COREA_1ST = 193,
    /// KIPO-KAIST Core-A 2nd generation processor family
    COREA_2ND = 194,
    /// Synopsys ARCompact V2
    ARC_COMPACT2 = 195,
    /// Open8 8-bit RISC soft processor core
    OPEN8 = 196,
    /// Renesas RL78 family
    RL78 = 197,
    /// Broadcom VideoCore V processor
    VIDEOCORE5 = 198,
    /// Renesas 78KOR family
    @"78KOR" = 199,
    /// Freescale 56800EX Digital Signal Controller (DSC)
    @"56800EX" = 200,
    /// Beyond BA1 CPU architecture
    BA1 = 201,
    /// Beyond BA2 CPU architecture
    BA2 = 202,
    /// XMOS xCORE processor family
    XCORE = 203,
    /// Microchip 8-bit PIC(r) family
    MCHP_PIC = 204,
    /// Reserved by Intel
    INTEL205 = 205,
    /// Reserved by Intel
    INTEL206 = 206,
    /// Reserved by Intel
    INTEL207 = 207,
    /// Reserved by Intel
    INTEL208 = 208,
    /// Reserved by Intel
    INTEL209 = 209,
    /// KM211 KM32 32-bit processor
    KM32 = 210,
    /// KM211 KMX32 32-bit processor
    KMX32 = 211,
    /// KM211 KMX16 16-bit processor
    KMX16 = 212,
    /// KM211 KMX8 8-bit processor
    KMX8 = 213,
    /// KM211 KVARC processor
    KVARC = 214,
    /// Paneve CDP architecture family
    CDP = 215,
    /// Cognitive Smart Memory Processor
    COGE = 216,
    /// Bluechip Systems CoolEngine
    COOL = 217,
    /// Nanoradio Optimized RISC
    NORC = 218,
    /// CSR Kalimba architecture family
    CSR_KALIMBA = 219,
    /// Zilog Z80
    Z80 = 220,
    /// Controls and Data Services VISIUMcore processor
    VISIUM = 221,
    /// FTDI Chip FT32 high performance 32-bit RISC architecture
    FT32 = 222,
    /// Moxie processor family
    MOXIE = 223,
    /// AMD GPU architecture
    AMDGPU = 224,
    /// RISC-V
    RISCV = 243,
    /// Lanai processor
    LANAI = 244,
    /// CEVA Processor Architecture Family
    CEVA = 245,
    /// CEVA X2 Processor Family
    CEVA_X2 = 246,
    /// Linux BPF – in-kernel virtual machine
    BPF = 247,
    /// Graphcore Intelligent Processing Unit
    GRAPHCORE_IPU = 248,
    /// Imagination Technologies
    IMG1 = 249,
    /// Netronome Flow Processor (NFP)
    NFP = 250,
    /// NEC Vector Engine
    VE = 251,
    /// C-SKY processor family
    CSKY = 252,
    /// Synopsys ARCv2.3 64-bit
    ARC_COMPACT3_64 = 253,
    /// MOS Technology MCS 6502 processor
    MCS6502 = 254,
    /// Synopsys ARCv2.3 32-bit
    ARC_COMPACT3 = 255,
    /// Kalray VLIW core of the MPPA processor family
    KVX = 256,
    /// WDC 65816/65C816
    @"65816" = 257,
    /// Loongson Loongarch
    LOONGARCH = 258,
    /// ChipON KungFu32
    KF32 = 259,
    /// LAPIS nX-U16/U8
    U16_U8CORE = 260,
    /// Reserved for Tachyum processor
    TACHYUM = 261,
    /// NXP 56800EF Digital Signal Controller (DSC)
    @"56800EF" = 262,
    /// Solana Bytecode Format
    SBF = 263,
    /// AMD/Xilinx AIEngine architecture
    AIENGINE = 264,
    /// SiMa MLA
    SIMA_MLA = 265,
    /// Cambricon BANG
    BANG = 266,
    /// Loongson LoongGPU
    LOONGGPU = 267,
    /// Wuxi Institute of Advanced Technology SW64
    SW64 = 268,
    /// AMD/Xilinx AIEngine ctrlcode
    AIECTRLCODE = 269,

    // Above here was taken from https://gabi.xinuos.com/elf/a-emachine.html
    //
    // Below here are additional values present in `std.elf.EM`

    /// AVR
    AVR_OLD = 0x1057,
    /// MSP430
    MSP430_OLD = 0x1059,
    /// Morpho MT
    MT = 0x2530,
    /// FR30
    CYGNUS_FR30 = 0x3330,
    /// WebAssembly (as used by LLVM)
    WEBASSEMBLY = 0x4157,
    /// Infineon Technologies 16-bit microcontroller with C166-V2 core
    XC16X = 0x4688,
    /// Freescale S12Z
    S12Z = 0x4def,
    /// DLX
    DLX = 0x5aa5,
    /// FRV
    CYGNUS_FRV = 0x5441,
    /// D10V
    CYGNUS_D10V = 0x7650,
    /// D30V
    CYGNUS_D30V = 0x7676,
    /// Ubicom IP2xxx
    IP2K_OLD = 0x8217,
    /// Cygnus PowerPC ELF
    CYGNUS_POWERPC = 0x9025,
    /// Alpha
    ALPHA = 0x9026,
    /// Cygnus M32R ELF
    CYGNUS_M32R = 0x9041,
    /// V850
    CYGNUS_V850 = 0x9080,
    /// Old S/390
    S390_OLD = 0xa390,
    /// Old unofficial value for Xtensa
    XTENSA_OLD = 0xabc7,
    /// Xstormy16
    XSTORMY16 = 0xad45,
    /// MN10300
    CYGNUS_MN10300 = 0xbeef,
    /// MN10200
    CYGNUS_MN10200 = 0xdead,
    /// Renesas M32C and M16C
    M32C_OLD = 0xfeb0,
    /// Vitesse IQ2000
    IQ2000 = 0xfeba,
    /// NIOS
    NIOS32 = 0xfebb,
    /// Toshiba MeP
    CYGNUS_MEP = 0xf00d,
    /// Old unofficial value for Moxie
    MOXIE_OLD = 0xfeed,
    /// Old MicroBlaze
    MICROBLAZE_OLD = 0xbaab,
    /// Adapteva's Epiphany architecture
    ADAPTEVA_EPIPHANY = 0x1223,

    /// Parallax Propeller (P1)
    /// This value is an unofficial ELF value used in: https://github.com/parallaxinc/propgcc
    PROPELLER = 0x5072,

    /// Parallax Propeller 2 (P2)
    /// This value is an unofficial ELF value used in: https://github.com/ne75/llvm-project
    PROPELLER2 = 300,

    _,
};
