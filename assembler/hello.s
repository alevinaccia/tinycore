# Home / menu / synth / Mac control. LEDs show mode.
# Mac control: send D<0..255> + Enter from screen to set the motor duty.
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
.equ UART_RXDATA,  0x31C        # read pops the byte
.equ UART_RXSTAT,  0x31D        # bit 0 = byte ready, bit 1 = framing err (clear on read)
.equ DAC_CTRL,     0x340
.equ DAC_CMP,      0x341        # bit 0 = cmp output
.equ PWM_DUTY_STAT, 0x342        # bit 0 = gap settled, sample now
.equ PWM_DUTY,  0x350            # duty 0..255
.equ PWM_SETTLE, 0x351           # settle, 3.85 us units

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
.equ M_ADC,     4
.equ M_RX,      5

.data
# strings first: li needs addresses < 256. 16 chars per lcd line
scr:            .asciz "UART div     000k2/k3: back"
startup:        .asciz "progetto efes   k0+k1 for menu"
playing:        .asciz "Playing...      Ode to Joy"
synth_s:        .asciz "Synth: k0-k3    hold k0+k1 menu"
# menu items: max 16 chars, hint goes on line 2
m0:             .asciz "Play Ode to Joy"
m1:             .asciz "Home"
m2:             .asciz "Synth"
m3:             .asciz "Check UART"
m4:             .asciz "Read ADC"
m5:             .asciz "Mac control"
hint:           .asciz "k3 next   k2 ok"
adc_scr:        .asciz "ADC 000 duty 000k0- k1+  k2 back"
rx_scr:         .asciz "duty 000 err 000k2 back"
.equ N_ITEMS,   6
menu:           .byte m0, m1, m2, m3, m4, m5
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

rx_ch:          .byte 0          # last received char
rx_st:          .byte 0          # last RXSTAT
rx_val:         .byte 0          # number being parsed
rx_on:          .byte 0          # 1 = inside a D command
rx_err:         .byte 0          # lost / bad commands

# Ode to Joy: C=1 D=2 E=3 F=4 G=5, 0 ends
mel_n:  .byte 3,3,4,5,5,4,3,2,1,1,2,3,3,2,2,0
mel_d:  .byte Q,Q,Q,Q,Q,Q,Q,Q,Q,Q,Q,Q,30,10,40

.text
        call go_home
# ~15 ms tick
main:   call pollbtns
        call leds
        call dac
        call adc_tick
        call rx_poll
        li   a, 1
        call wait
        lb   a, cnt
        addi a, a, 1
        sb   a, cnt
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
          call printscreen
          call send_new_line
          li a, 16            # hint always on line 2
          sb a, line_cur
          li a, hint
          mv b, a
          j ploop

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
          beq a, 3, show_uart
          beq a, 4, go_adc
          j go_rx
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
# sync to the start of a settled gap (hw waits out the kick)
w_rdy1: lb a, PWM_DUTY_STAT     # skip a window already in progress
        andi a, a, 1
        bnz w_rdy1
w_rdy0: lb a, PWM_DUTY_STAT
        andi a, a, 1
        bz w_rdy0

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
          beq a, M_ADC, adc_keys
          beq a, M_RX, uart_keys
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

# --- adc screen ---
go_adc:   li a, M_ADC
          sb a, mode
          li a, adc_scr
          mv b, a
          call printscreen
          j adc_show

# refresh every 8 ticks (~120 ms) in adc mode
adc_tick: lb a, mode
          bne a, M_ADC, at_done
          lb a, cnt
          andi a, a, 7
          bnz at_done
          j adc_show
at_done:  ret

# adc_show: reading at col 4, duty at col 13, no clear (no flicker)
adc_show: li a, 0x84
          call lcd_cmd
          lb a, dac_res
          sb a, uv
          call put3
          li a, 0x8D
          call lcd_cmd
          lb a, PWM_DUTY
          sb a, uv
          j put3

# put3: uv as 3 decimal digits at cursor
put3:     li a, 100
          sb a, dv
          call udig
          call drawc
          li a, 10
          sb a, dv
          call udig
          call drawc
          lb a, uv
          addi a, a, '0'
          j drawc

# adc keys: k0 duty-16, k1 duty+16, k2/k3 back
adc_keys: lb a, kboard
          andi a, a, KEY2_PRESSED + KEY3_PRESSED
          bz ak0
          li a, M_MENU
          sb a, mode
          j show_menu
ak0:      lb a, kboard
          andi a, a, KEY0_PRESSED
          bz ak1
          lb a, PWM_DUTY
          bltu a, 16, ak_zero
          subi a, a, 16
          j ak_set
ak_zero:  li a, 0
ak_set:   sb a, PWM_DUTY
ak1:      lb a, kboard
          andi a, a, KEY1_PRESSED
          bz polldone
          lb a, PWM_DUTY
          bgeu a, 240, polldone
          addi a, a, 16
          sb a, PWM_DUTY
          j polldone

# --- mac control: D<n> + Enter sets PWM_DUTY ---
go_rx:    li a, M_RX
          sb a, mode
          li a, 0
          sb a, rx_on
          lb a, UART_RXDATA   # drop a stale byte
          li a, rx_scr
          mv b, a
          call printscreen
          j rx_show

# rx_poll: drain received bytes, echo them, parse
rx_poll:  lb a, mode
          bne a, M_RX, rp_ret
rp_loop:  lb a, UART_RXSTAT
          sb a, rx_st
          andi a, a, 2
          bz rp_avail
          call rx_bump        # framing error
rp_avail: lb a, rx_st
          andi a, a, 1
          bz rp_show
          lb a, UART_RXDATA
          sb a, rx_ch
          call putc           # echo
          lb a, rx_ch
          beq a, 'D', rp_d
          beq a, 13, rp_cr
          bltu a, '0', rp_loop    # not a digit: drop
          bgeu a, '9' + 1, rp_loop
          lb a, rx_on         # digit outside a command: drop
          bz rp_loop
          lb a, rx_val        # val = val * 10 + digit
          slli a, a, 1
          mv b, a
          slli a, a, 2
          add a, a, b
          mv b, a
          lb a, rx_ch
          subi a, a, '0'
          add a, a, b
          sb a, rx_val
          j rp_loop
rp_d:     lb a, rx_on         # D inside a command: previous one lost
          bz rp_d1
          call rx_bump
rp_d1:    li a, 1
          sb a, rx_on
          li a, 0
          sb a, rx_val
          j rp_loop
rp_cr:    li a, '\n'
          call putc
          lb a, rx_on
          bz rp_loop
          lb a, rx_val
          sb a, PWM_DUTY
          li a, 0
          sb a, rx_on
          call rx_ack
          j rp_loop
rp_show:  lb a, cnt           # refresh every 8 ticks
          andi a, a, 7
          bnz rp_ret
          j rx_show
rp_ret:   ret

# rx_ack: "OK nnn" + CRLF with the new duty
rx_ack:   li a, 'O'
          call putc
          li a, 'K'
          call putc
          li a, ' '
          call putc
          lb a, PWM_DUTY
          sb a, uv
          li a, 100
          sb a, dv
          call udig
          call putc
          li a, 10
          sb a, dv
          call udig
          call putc
          lb a, uv
          addi a, a, '0'
          call putc
          li a, '\r'
          call putc
          li a, '\n'
          j putc

rx_bump:  lb a, rx_err
          addi a, a, 1
          sb a, rx_err
          ret

# rx_show: duty at col 5, errors at col 13
rx_show:  li a, 0x85
          call lcd_cmd
          lb a, PWM_DUTY
          sb a, uv
          call put3
          li a, 0x8D
          call lcd_cmd
          lb a, rx_err
          sb a, uv
          j put3

# lcd_cmd: send command a
lcd_cmd:  sb a, tmp
lcw:      lb a, LCD_STAT
          andi a, a, 1
          bnz lcw
          lb a, tmp
          sb a, LCD_CMD
          ret

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
