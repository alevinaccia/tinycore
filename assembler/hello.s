# Home / menu / synth. LEDs show mode.
# Home: k0+k1 -> menu. Menu: k3 next, k2 select. Synth: k0-k3 play, hold k0+k1 1 s -> menu.
# Mac: screen /dev/cu.usbserial-* 115200
# TICK 15 ms -> Get timings as S/TICK

.equ LED,          0x300
.equ BTNS,         0x301        
.equ S1_PRESSED,   0x10        
.equ S2_PRESSED,   0x20
.equ KEYBOARD,     0x302
.equ KEY0_PRESSED, 0x10
.equ KEY1_PRESSED, 0x20
.equ KEY2_PRESSED, 0x40
.equ KEY3_PRESSED, 0x80
.equ KEY0_HELD,    0x01
.equ KEY1_HELD,    0x02
.equ KEY2_HELD,    0x04
.equ KEY3_HELD,    0x08
.equ UART_DATA,    0x319
.equ UART_STAT,    0x31A        # bit 0 = busy
.equ UART_DIV,     0x31B        # default to 234
.equ DAC_CTRL,     0x340
.equ DAC_CMP,      0x341        # bit 0 = cmp output

.equ LCD_CMD,   0x320
.equ LCD_DATA,  0x321
.equ LCD_STAT,  0x322        # bit 0 = busy
.equ BUZ,       0x330        # 0 off, 1..7 = C6..B6
.equ Q, 20                   # quarter, ~15 ms units
.equ D3, 34                  # ~0.5 s @ 27 MHz
.equ D2, 255

.equ HOLD_1S,   67           # 67*15ms ~= 1s

.equ M_HOME,    0
.equ M_MENU,    1
.equ M_SYNTH,   2
.equ M_UART,    3

.data
# strings first: li needs addresses < 256. 16 chars per lcd line
scr:            .asciz "UART div     000k2/k3: back"
startup:        .asciz "progetto efes   k0+k1 for menu"
playing:        .asciz "Playing...      Ode to Joy"
synth_s:        .asciz "Synth: k0-k3    hold k0+k1 menu"
m0:             .asciz "Play Ode to Joy k3 next   k2 ok"
m1:             .asciz "Home            k3 next   k2 ok"
m2:             .asciz "Synth           k3 next   k2 ok"
m3:             .asciz "Check UART      k3 next   k2 ok"
.equ N_ITEMS,   4
menu:           .byte m0, m1, m2, m3
menu_sel:       .byte 0
mode:           .byte 0

btns:           .byte 0
kboard:         .byte 0
line_cur:       .byte 0
line_cnt:       .byte 0
tmp:            .byte 0
cnt:            .byte 0
d2:             .byte 0
d3:             .byte 0
is_clear:       .byte 0
note:           .byte 0
hold:           .byte 0
uv:             .byte 0          # udig value
dv:             .byte 0          # udig step
dch:            .byte 0          # udig digit

dac_bit:        .byte 32
dac_res:        .byte 0
dac_guess:      .byte 0
wait_time:      .byte 0

# Ode to Joy: C=1 D=2 E=3 F=4 G=5, 0 ends
mel_n:  .byte 3,3,4,5,5,4,3,2,1,1,2,3,3,2,2,0
mel_d:  .byte Q,Q,Q,Q,Q,Q,Q,Q,Q,Q,Q,Q,30,10,40

.text
        call go_home
# ~15 ms tick: poll every pass, print every 32
main:   call pollbtns
        call leds
        call dac
        li   a, 1
        call wait
        lb   a, cnt
        addi a, a, 1
        sb   a, cnt
        andi a, a, 31
        bnz  main
        li   a, 0
        mv   b, a
        call puts            # print msg
        lb   a, cnt
        srli a, a, 5
        call puthex          # print counter
        li   a, '\r'
        call putc
        li   a, '\n'
        call putc
        j    main

# --- modes (tail-called, ret goes to caller) ---
go_home:  li a, M_HOME
          sb a, mode
          li a, startup
          mv b, a
          j printscreen

enter_menu:
          li a, M_MENU
          sb a, mode
          li a, 0
          sb a, BUZ           # silence synth
          sb a, menu_sel
show_menu:
          lb a, menu_sel
          mv b, a
          lb a, menu(b)
          mv b, a
          j printscreen

go_synth: li a, M_SYNTH
          sb a, mode
          li a, 0
          sb a, hold
          li a, synth_s
          mv b, a
          j printscreen

menu_next:
          lb a, menu_sel
          addi a, a, 1
          bne a, N_ITEMS, nsave
          li a, 0             # wrap
nsave:    sb a, menu_sel
          j show_menu

menu_select:
          lb a, menu_sel
          beq a, 0, sel_ode
          beq a, 1, go_home
          beq a, 2, go_synth
          j show_uart
sel_ode:  li a, playing
          mv b, a
          call printscreen
          call melody
          lb a, KEYBOARD      # drop presses made during the song
          j show_menu

# --- dac   ---
dac:    li a, 0  
        sb a, dac_res   # zero the result "register"
        li a, 32
        sb a, dac_bit

dac_loop:
        li a, 40
        sb a, wait_time
        lb a, dac_res
        mv b, a         # b = result
        lb a, dac_bit   # a = bit
        or a, a, b      # a = result | bit
        sb a, dac_guess # guess = result | bit

        sb a, DAC_CTRL

        # wait to settle
        lb a, wait_time
settle: addi a, a, -1
        bnz settle


        lb a, DAC_CMP   # a = cmp
        mv b, a         # b = cmp
        li a, 1         # a = 1
        bne a, b, shift 
        lb a, dac_guess
        sb a, dac_res

shift:  lb a, dac_bit
        srli a, a, 1     #  bit >> 1 
        sb a, dac_bit
        mv b, a         # b = dac_bit
        li a, 0         # a = 0
        bne a, b, dac_loop
        ret
        
        
          

# --- input ---
pollbtns: lb a, BTNS 
          sb a, btns
          andi a, a, S1_PRESSED
          bz chk2
          call on_s1
chk2:     lb a, btns
          andi a, a, S2_PRESSED
          bz chkkey
          call on_s2

chkkey:   lb a, KEYBOARD
          sb a, kboard
          li a, 0
          sb a, note
          lb a, mode
          beq a, M_MENU, menu_keys
          beq a, M_SYNTH, synth_keys
          beq a, M_UART, uart_keys
          lb a, kboard        # home: k0+k1 -> menu
          andi a, a, KEY0_HELD + KEY1_HELD
          bne a, KEY0_HELD + KEY1_HELD, polldone
          j enter_menu

menu_keys:
          lb a, kboard
          andi a, a, KEY3_PRESSED
          bz mk_sel
          call menu_next
mk_sel:   lb a, kboard
          andi a, a, KEY2_PRESSED
          bz polldone
          j menu_select       # tail call: saves a stack slot

uart_keys:                    # k2 or k3 -> back to menu
          lb a, kboard
          andi a, a, KEY2_PRESSED + KEY3_PRESSED
          bz polldone
          li a, M_MENU
          sb a, mode
          j show_menu

synth_keys:
          lb a, kboard
          andi a, a, KEY0_HELD + KEY1_HELD
          bne a, KEY0_HELD + KEY1_HELD, s_free
          lb a, hold          # k0+k1 held: mute, count 1 s
          addi a, a, 1
          sb a, hold
          bne a, HOLD_1S, polldone
          j enter_menu
s_free:   li a, 0
          sb a, hold
          lb a, kboard        # highest held key wins
          andi a, a, KEY0_HELD
          bz chk_k1
          li a, 1             # C
          sb a, note
chk_k1:   lb a, kboard
          andi a, a, KEY1_HELD
          bz chk_k2
          li a, 2             # D
          sb a, note
chk_k2:   lb a, kboard
          andi a, a, KEY2_HELD
          bz chk_k3
          li a, 3             # E
          sb a, note
chk_k3:   lb a, kboard
          andi a, a, KEY3_HELD
          bz polldone
          li a, 4             # F
          sb a, note

polldone: lb a, note
          sb a, BUZ
          ret


on_s1:    lb a, UART_DIV     
          addi a, a, 6
          sb a, UART_DIV
          j uart_refresh

on_s2:    li a, 234
          sb a, UART_DIV
uart_refresh:                 # redraw if uart screen is open
          lb a, mode
          bne a, M_UART, urdone
          j show_uart
urdone:   ret

# show_uart: divider as 3 decimal digits on lcd
show_uart:
          li a, M_UART
          sb a, mode
          lb a, UART_DIV
          sb a, uv
          li a, 100
          sb a, dv
          call udig
          sb a, scr+13
          li a, 10
          sb a, dv
          call udig
          sb a, scr+14
          lb a, uv            # ones left over
          addi a, a, '0'
          sb a, scr+15
          li a, scr
          mv b, a
          j printscreen

# udig: a = '0' + uv / dv, uv %= dv (repeated subtraction)
udig:     li a, '0'
          sb a, dch
ud1:      lb a, dv
          mv b, a
          lb a, uv
          bltu a, b, ud2
          sub a, a, b
          sb a, uv
          lb a, dch
          addi a, a, 1
          sb a, dch
          j ud1
ud2:      lb a, dch
          ret


clear_lcd:lb a, LCD_STAT
          andi a, a, 1
          bnz clear_lcd
          li a, 0x01
          sb a, LCD_CMD
          li a, 1
          sb a, is_clear
          ret

# printscreen: draw string at address b, 16 chars per line, max 32
printscreen:
        call clear_lcd
        li   a, 0
        sb   a, line_cur
ploop:  lb   a, 0(b)
        bz   pdone2           # end of string
        call drawc
        mv   a, b
        addi a, a, 1
        mv   b, a
        lb   a, line_cur
        addi a, a, 1
        sb   a, line_cur
        beq  a, 32, pdone2    # screen full
        bne  a, 16, ploop
        call send_new_line
        j    ploop
pdone2: ret

send_new_line:
        lb a, LCD_STAT
        andi a, a, 1
        bnz send_new_line
        li a, 0xC0 # set cursor to new line
        sb a, LCD_CMD
        ret

# tmp has to have the character to print
drawc:  sb   a, tmp
dwait:  lb   a, LCD_STAT
        andi a, a, 1
        bnz dwait
        lb   a, tmp
        sb   a, LCD_DATA
        ret

# putc: send a. waits while TX busy. keeps b.
putc:   sb   a, tmp
pwait:  lb   a, UART_STAT
        andi a, a, 1
        bnz  pwait
        lb   a, tmp
        sb   a, UART_DATA
        ret

# puts: send string at msg + b until 0.
puts:   lb   a, startup(b)
        bz   pdone
        call putc
        mv   a, b
        addi a, a, 1
        mv   b, a
        j    puts
pdone:  ret


# puthex: send a as two hex digits. uses b.
puthex: mv   b, a
        srli a, a, 4
        call hexd
        mv   a, b
        andi a, a, 0x0F
        call hexd
        ret
hexd:   bltu a, 10, hnum
        addi a, a, 'A' - 10 - '0'
hnum:   addi a, a, '0'
        j    putc            # tail call: putc returns to our caller

# leds: LED0 = menu, LED1 = synth, both = uart
leds:   lb a, mode
        sb a, LED
        ret


# melody: play mel_n/mel_d once. uses b.
melody: li   a, 0
        mv   b, a
mloop:  lb   a, mel_n(b)
        bz   mdone
        sb   a, BUZ
        lb   a, mel_d(b)
        call wait
        li   a, 0            # short gap between notes
        sb   a, BUZ
        li   a, 2
        call wait
        mv   a, b
        addi a, a, 1
        mv   b, a
        j    mloop
mdone:  sb   a, BUZ
        ret

# wait: a * ~15 ms. keeps b.
delay:  li   a, D3
wait:   sb   a, d3
dl3:    li   a, D2
        sb   a, d2
dl2:    li   a, 0
dl1:    addi a, a, -1
        bnz  dl1
        lb   a, d2
        addi a, a, -1
        sb   a, d2
        bnz  dl2
        lb   a, d3
        addi a, a, -1
        sb   a, d3
        bnz  dl3
        ret
