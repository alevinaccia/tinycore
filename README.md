# TinyCore

An 8-bit CPU and SoC written in VHDL for the Sipeed Tang Nano 20K (Gowin GW2AR-18, 27 MHz), built for the *Electronics for Embedded Systems* course. The CPU runs a menu-driven program on a 16x2 LCD. The program covers a 4-key synth, a melody player, a UART check screen, and DC motor speed control. Motor speed is measured through back-EMF, using a R-2R DAC, a comparator and a software SAR loop. The motor duty can also be set from a Mac over UART.

## Course requirements

| Requirement | How it is satisfied |
|---|---|
| **Memories** | Harvard memory system designed around the core. IMEM is 1K x 16 and DMEM is 512 x 8, both written as synchronous-read arrays so synthesis maps them to block RAM (BSRAM). The requirement will be satisfied with a memory controller for the SDRAM Chip present on the board. |
| **Programmable logic** | Everything on the FPGA is written in VHDL: the CPU, bus, memories and every peripheral. |
| **Interconnections** | UART 8N1 TX and RX to a Mac through the board's BL616 USB bridge, with a programmable baud divider. HD44780 4-bit parallel protocol to the LCD. The Mac side is a Web Serial dashboard (`tools/dashboard.html`). If i have time the program will not be flashed at program time but will be sent over SPI by an Arduino UNO, this will require an SPI protocol implementation and a bootloader|
| **Processor peripherals** | Every peripheral is a memory-mapped register block that the assembly program drives directly with `lb`/`sb`, with no driver layer. Status is read by polling busy and ready flags. |
| **AD/DA conversion** | 6-bit R-2R ladder DAC (10k/20k) driven by 6 FPGA pins, plus an LM393 comparator whose output goes through a 2-FF synchronizer. Software successive approximation (6 steps, MSB first) turns this into an ADC. It measures the motor's back-EMF through a 10k/20k divider. |
| **Power management** | DC motor drive through an L293D H-bridge with a ~1 kHz PWM. Every 16th period the bridge is switched off, and a settle timer flags when the back-EMF can be sampled. A bulk capacitor absorbs motor inrush on the USB supply. The core also has a `WFI` sleep state, woken by a button press, and a clock-enable input. Probably need further development |

## CPU architecture

- **Data width**: 8 bits. Registers: `a` (accumulator) and `b` (operand / index). ALU results always go to `a`.
- **Instructions**: 16 bits, `[15:12] op | [11] X | [10] V | [9:0] address / immediate`.
- **Memory**: Harvard. A 10-bit PC addresses IMEM (1024 words); a 10-bit data address covers DMEM and MMIO.
- **Flags**: `Z` (zero) and `C` (carry; borrow after a subtract). There are no N/V flags, so only unsigned compares exist.
- **Stack**: a 4-entry return-address stack in flip-flops, with no overflow check.
- **Execution**: multicycle FSM with the states `FETCH → DECODE → EXEC` (3 cycles), or `FETCH → DECODE → MEM` for loads and stores. MEM waits for `ready`, so loads and stores take 4 cycles on this SoC. `SLEEP` is entered by `WFI`.
- **Addressing**: `lb`/`sb` with X=1 use `addr + b` (indexed). The effective address is computed in DECODE, so the bus request starts one cycle early.
- **Bus**: `addr`, `wdata`, `we` and `valid` go out; `rdata` and `ready` come back. Each slave answers in one cycle.

### Instruction set

| op | Assembly | Operation | Flags |
|---|---|---|---|
| 0 | `nop` | nothing | – |
| 1 | `li a, imm` | a = imm8 | Z |
| 2 | `lb a, ADDR` / `lb a, ADDR(b)` | a = mem[ADDR (+b)] | Z |
| 3 | `sb a, ADDR` / `sb a, ADDR(b)` | mem[ADDR (+b)] = a | – |
| 4 | `mv b, a` (V=0) / `mv a, b` (V=1) | copy register | Z (only `mv a, b`) |
| 5 | `add a, a, b` / `adc a, a, b` / `adci a, a, imm` | a = a + b or imm (+C when V=1) | C, Z |
| 6 | `sub a, a, b` / `subi a, a, imm`; V=1 = compare | a − b or imm (result discarded on compare) | C (borrow), Z |
| 7 | `and a, a, b` / `andi a, a, imm` | a = a & b or imm | Z |
| 8 | `or a, a, b` / `ori a, a, imm` | a = a \| b or imm | Z |
| 9 | `xor a, a, b` / `xori a, a, imm` | a = a ^ b or imm | Z |
| 10 | `slli` (V=0), `srli` (V=1, X=0), `srai` (V=1, X=1) | 1-bit shift; the assembler repeats it n times | C (bit shifted out), Z |
| 11 | `addi a, a, imm` | a = a + imm8 | C, Z |
| 12 | `j label` | pc = addr10 | – |
| 13 | `bz`, `bnz`, `bc`, `bnc label` | V selects Z or C, X negates; branch if true | – |
| 14 | `call label` (V=0) / `ret` (V=1) | push / pop return address | – |
| 15 | `wfi` | sleep until a button press | – |

For ops 5–9, X selects `imm8` instead of `b`.

**Pseudo-instructions** (assembler): `not a, a` (= `xori 0xFF`), `beq`/`bne`/`bltu`/`bgeu a, b|imm, label` (compare + branch, 2 words), `beqz`/`bnez a, label`.

### Assembler

`assembler/tasm.py` is a two-pass assembler with RISC-V-style syntax. It produces `src/prog_pkg.vhd`, which initializes IMEM and DMEM, so a program change means resynthesis.

Directives: `.equ`, `.text`, `.data`, `.byte`, `.ascii`, `.asciz`. Comments start with `#` or `//`.

```
python3 assembler/tasm.py assembler/hello.s -o src/prog_pkg.vhd [-l hello.lst]
```

## Memory map

| Address | Content |
|---|---|
| `0x000–0x1FF` | DMEM (512 B). Holds strings and variables. |
| `0x200–0x3FF` | MMIO (bit 9 = 1). Only `0x300` and above is decoded. |

| Address | Register | R/W | Bits |
|---|---|---|---|
| `0x300` | LED | R/W | [1:0] LEDs (active high in software, inverted for the board) |
| `0x301` | BTN | R | [5:4] S1/S2 pressed (latched, cleared on read), [1:0] debounced level |
| `0x302` | KEYBOARD | R | [7:4] k0–k3 pressed (latched, cleared on read), [3:0] debounced level |
| `0x319` | UART_DATA | W | writing starts a transmission |
| `0x31A` | UART_STAT | R | [0] TX busy |
| `0x31B` | UART_DIV | R/W | clocks per bit (reset 234 → 115200 baud) |
| `0x31C` | UART_RXDATA | R | last received byte |
| `0x31D` | UART_RXSTAT | R | [0] byte valid, [1] framing error |
| `0x320` | LCD_CMD | W | send a command byte (RS=0) |
| `0x321` | LCD_DATA | W | send a character (RS=1) |
| `0x322` | LCD_STAT | R | [0] busy |
| `0x330` | BUZ | R/W | [2:0] note: 0 = off, 1..7 = C6..B6 |
| `0x340` | DAC_CTRL | W | [5:0] R-2R DAC code |
| `0x341` | DAC_CMP | R | [0] synchronized comparator output |
| `0x342` | PWM_STAT | R | [0] in the measurement gap and settled: sample now |
| `0x350` | PWM_DUTY | R/W | duty 0..255 |
| `0x351` | PWM_SETTLE | R/W | gap settle time in 3.85 µs ticks (reset 130 ≈ 500 µs) |
| `0x3FF` | DBG | W | debug port, pulses `dbg_we` (for simulation) |

## Peripherals

| Peripheral | File | Description |
|---|---|---|
| UART TX | `uart_tx.vhd` | 8N1 transmitter with a shift register. Bit time = `UART_DIV` clocks. |
| UART RX | `uart_rx.vhd` | 2-FF synchronized input. Checks the start bit at half a bit time, samples 8 data bits, and checks the stop bit (framing error). |
| LCD | `lcd.vhd` | HD44780 16x2 in 4-bit mode. Runs the power-on init from a ROM (40 ms wait, 0x3 resync nibbles, 4-bit mode, 2 lines, display on, clear). Each byte is sent as two nibbles with timed enable pulses: 40 µs per character, 1.5 ms per command. A busy flag is exposed to software. |
| Debounce | `debounce.vhd` | Generic N-bit debouncer: 2-FF synchronizer, sampled every 10 ms, with a one-cycle rising-edge pulse. One instance serves the 2 buttons and one the 4 keys. The SoC latches presses until they are read. |
| Buzzer | `buzzer.vhd` | Square-wave generator. The half-period table for C6..B6 is computed at elaboration from `CLK_HZ`. Drives a passive piezo through a series resistor. |
| PWM | `pwm.vhd` | 27 MHz / 104 / 256 ≈ 1 kHz with an 8-bit duty, shadowed so updates happen at the start of a period (no glitches). Every 16th period EN is held low. A settle counter then raises `ready` once the inductive kick has died out. |
| ADC front end | `adc.vhd` | Holds the 6-bit DAC code and synchronizes the comparator input (2 FFs). The SAR search runs in software. |

### Board connections (`tangnano20k.cst`)

| Signal | Pins | Connected to |
|---|---|---|
| `clk` | 4 | 27 MHz oscillator |
| `s1`, `s2` | 88, 87 | onboard buttons |
| `led[1:0]` | 15, 16 | onboard LEDs (active low) |
| `keyboard[3:0]` | 72, 71, 26, 29 | 4 push buttons with external pull-downs |
| `uart_tx`, `uart_rx` | 69, 70 | BL616 USB-UART bridge |
| `lcd_rs`, `lcd_en`, `lcd_data[3:0]` | 30, 31, 17, 20, 19, 18 | HD44780 LCD (D4–D7) |
| `buzz` | 79 | piezo buzzer |
| `pwm_en`, `pwm_pwr` | 86, 49 | L293D enable and input (held high) |
| `dac_ctrl[5:0]` | 75, 80, 76, 42, 77, 73 | R-2R ladder |
| `adc_cmp` | 27 | LM393 output |

The schematic is in `schem.excalidraw`.

## The program (`assembler/hello.s`)

The main loop runs every ~15 ms. Each pass polls the buttons and keys, writes the current mode to the LEDs, takes one back-EMF reading, refreshes the active screen, and handles UART input. At startup the LCD shows `progetto efes`. Holding k0+k1 opens the menu, where k3 moves to the next item and k2 selects it.

| Menu item | What it does |
|---|---|
| Play Ode to Joy | Plays the melody on the buzzer, using a note/duration table in DMEM. |
| Home | Returns to the start screen. |
| Synth | k0–k3 play C, D, E, F while held; the highest held key wins. Holding k0+k1 for 1 s returns to the menu. |
| Check UART | Shows the baud divider in decimal. S1 adds 6 to it (deliberate detuning, to show the link breaking); S2 restores 234. |
| Read ADC | Shows the back-EMF reading (0–63) and the PWM duty. k0/k1 change the duty by ±16. |
| Mac control | Takes `D<0..255>` + Enter over UART. Every character is echoed, the new duty is set and confirmed with `OK nnn`. The LCD shows the duty and an error count (framing errors and interrupted commands). |

**Back-EMF measurement:** the program waits for the start of a settled PWM gap (`PWM_STAT`). For each bit from 32 down to 1, it writes `result | bit` to the DAC, waits for the ladder to settle, and keeps the bit if the comparator reads 1.

**Mac dashboard:** `tools/dashboard.html` opens the serial port with Web Serial and has a duty slider. It sends each command one character at a time and waits for each character's echo before sending the next. The RX side has a single-byte register, so this pacing keeps bytes from being overwritten.

Other routines: LCD print with automatic jump to line 2 (`printscreen`), decimal conversion by repeated subtraction (`udig`, `put3`), `putc`/`puts`/`puthex` over UART, and nested-loop delays.

## Build

The tools come from OSS CAD Suite (`ghdl`, `yosys`, `nextpnr-himbaechel`, `gowin_pack`, `openFPGALoader`), plus `nvc` for simulation.

```
make          # bitstream -> build/top.fs
make prog     # load into SRAM
make flash    # write to SPI flash (persistent)
```