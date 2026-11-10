-- TinyCore SoC: core + IMEM 1Kx16 + DMEM 512x8 + MMIO peripherals + debug port
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.prog_pkg.all;

entity soc is
    generic (DEB_CYCLES : positive := 270000);   -- 10 ms @ 27 MHz
    port (
        clk, rst : in  std_logic;
        btn      : in  std_logic_vector(1 downto 0);  -- active high
        keyboard : in  std_logic_vector(3 downto 0);  -- active high
        led      : out std_logic_vector(1 downto 0);  -- active high
        uart_tx  : out std_logic;
        sleeping : out std_logic;
        lcd_rs   : out std_logic;
        lcd_en   : out std_logic;
        lcd_data : out std_logic_vector(3 downto 0);
        buzz     : out std_logic;
        pwm_pwr  : out std_logic;
        pwm_en   : out std_logic;
        dac_ctrl : out std_logic_vector(5 downto 0);
        adc_cmp  : in std_logic;
        rx_in    : in std_logic;

        -- debug bus
        dbg_we   : out std_logic;                     -- write to 0x3FF (sim)
        dbg_data : out std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of soc is
    -- MMIO from 0x200 to 0x3FF, used only from 0x300
    constant A_LED           : unsigned(9 downto 0) := to_unsigned(16#300#, 10);
    constant A_BTN           : unsigned(9 downto 0) := to_unsigned(16#301#, 10);
    constant A_KEYBOARD      : unsigned(9 downto 0) := to_unsigned(16#302#, 10);
    constant A_UDAT          : unsigned(9 downto 0) := to_unsigned(16#319#, 10);
    constant A_USTA          : unsigned(9 downto 0) := to_unsigned(16#31A#, 10);  -- bit0 = uart busy
    constant A_UDIV          : unsigned(9 downto 0) := to_unsigned(16#31B#, 10);
    constant A_URXDATA       : unsigned(9 downto 0) := to_unsigned(16#31C#, 10);
    constant A_URXSTAT       : unsigned(9 downto 0) := to_unsigned(16#31D#, 10);  -- bit0 data ready, bit1 framing err
    constant A_LCDCMD        : unsigned(9 downto 0) := to_unsigned(16#320#, 10);
    constant A_LCDDATA       : unsigned(9 downto 0) := to_unsigned(16#321#, 10);
    constant A_LCDSTAT       : unsigned(9 downto 0) := to_unsigned(16#322#, 10);  -- bit0 = lcd busy
    constant A_BUZ           : unsigned(9 downto 0) := to_unsigned(16#330#, 10);
    constant A_DACCTRL       : unsigned(9 downto 0) := to_unsigned(16#340#, 10);
    constant A_DACCMP        : unsigned(9 downto 0) := to_unsigned(16#341#, 10);
    constant A_PWM_DUTY_STAT : unsigned(9 downto 0) := to_unsigned(16#342#, 10);  -- bit0 = sample ready
    constant A_PWM_DUTY      : unsigned(9 downto 0) := to_unsigned(16#350#, 10);
    constant A_PWM_SETTLE    : unsigned(9 downto 0) := to_unsigned(16#351#, 10);

    constant A_DBG : unsigned(9 downto 0) := to_unsigned(16#3FF#, 10);

    signal imem : imem_t := IMEM_INIT;
    signal dmem : dmem_t := DMEM_INIT;

    signal iaddr          : unsigned(9 downto 0);
    signal idata          : std_logic_vector(15 downto 0) := (others => '0');
    signal addr           : unsigned(9 downto 0);
    signal wdata, rdata   : std_logic_vector(7 downto 0) := (others => '0');
    signal dq             : std_logic_vector(7 downto 0) := (others => '0');
    signal we, valid      : std_logic;
    signal dac_we         : std_logic;
    signal ready          : std_logic := '0';
    signal sel_ram        : std_logic := '0';
    signal io_q           : std_logic_vector(7 downto 0) := (others => '0');

    signal led_r          : std_logic_vector(1 downto 0) := (others => '0');
    signal bdeb, brise    : std_logic_vector(1 downto 0);
    signal bpress         : std_logic_vector(1 downto 0) := (others => '0');
    signal kdeb, krise    : std_logic_vector(3 downto 0);
    signal kpress         : std_logic_vector(3 downto 0) := (others => '0');
    signal wake           : std_logic;

    signal u_div          : unsigned(7 downto 0) := to_unsigned(0, 8);
    signal u_tx_data      : std_logic_vector(7 downto 0) := (others => '0');
    signal u_tx_start, u_tx_busy : std_logic := '0';
    signal u_rx_valid, u_rx_error : std_logic := '0';
    signal u_rx_byte      : std_logic_vector(7 downto 0) := (others => '0');

    signal lcd_data_in    : std_logic_vector(7 downto 0) := (others => '0');
    signal lcd_start, lcd_busy, lcd_rs_in : std_logic := '0';

    signal dac_data_in    : std_logic_vector(5 downto 0);
    signal dac_cmp_s      : std_logic;
    signal buz_note       : std_logic_vector(2 downto 0) := "000";
    signal pwm_duty       : unsigned(7 downto 0) := (others => '0');
    signal pwm_settle     : unsigned(7 downto 0) := to_unsigned(130, 8);  -- ~500 us
    signal pwm_rdy        : std_logic;

    signal first          : std_logic;
begin
    core : entity work.tinycore
        port map (clk => clk, rst => rst, ce => '1',
                  iaddr => iaddr, idata => idata,
                  addr => addr, wdata => wdata, we => we, valid => valid,
                  rdata => rdata, ready => ready,
                  wake => wake, sleeping => sleeping);

    u_tx : entity work.uart_tx
        port map (clk => clk, rst => rst, div => u_div, data => u_tx_data, start => u_tx_start, busy => u_tx_busy, tx => uart_tx);

    u_rx: entity work.uart_rx
     port map(
        clk => clk,
        data_in => rx_in,
        div => u_div,
        valid => u_rx_valid,
        err => u_rx_error,
        rx_byte => u_rx_byte
    );

    lcd_ctrl : entity work.lcd port map (clk => clk, lcd_rs => lcd_rs, lcd_en => lcd_en, lcd_data => lcd_data, data_in => lcd_data_in, start => lcd_start, busy => lcd_busy, reset_in => rst, rs_in => lcd_rs_in);

    btn_db : entity work.debounce
        generic map (WIDTH => 2, CYCLES => DEB_CYCLES)
        port map (clk => clk, rst => rst, din => btn, q => bdeb, rise => brise);

    key_db : entity work.debounce
        generic map (WIDTH => 4, CYCLES => DEB_CYCLES)
        port map (clk => clk, rst => rst, din => keyboard, q => kdeb, rise => krise);

    buz : entity work.buzzer port map (clk => clk, rst => rst, note => buz_note, pin => buzz);

    pwm_inst: entity work.pwm
     port map(
        clk => clk,
        duty_in => std_logic_vector(pwm_duty),
        settle_in => std_logic_vector(pwm_settle),
        en => pwm_en,
        pwr => pwm_pwr,
        ready => pwm_rdy
    );

    dac_inst: entity work.adc
     port map(
        clk => clk,
        we  => dac_we,
        din => dac_data_in,
        ctrl => dac_ctrl,
        cmp_in => adc_cmp,
        cmp => dac_cmp_s
    );

    -- IMEM: sync read
    process (clk) begin
        if rising_edge(clk) then
            idata <= imem(to_integer(iaddr));
        end if;
    end process;

    -- DMEM: sync read/write (first beat only)
    first <= valid and not ready;
    process (clk) begin
        if rising_edge(clk) then
            if first = '1' and we = '1' and addr(9) = '0' then
                dmem(to_integer(addr(8 downto 0))) <= wdata;
            end if;
            dq <= dmem(to_integer(addr(8 downto 0)));
        end if;
    end process;

    -- bus: every slave answers in 1 cycle, ready held while valid
    process (clk)
        variable bp : std_logic_vector(1 downto 0);
        variable kp : std_logic_vector(3 downto 0);
    begin
        if rising_edge(clk) then
            bp := bpress;
            kp := kpress;
            if rst = '1' then
                ready <= '0'; led_r <= (others => '0'); dbg_we <= '0';
                bpress <= "00"; kpress <= "0000";
                u_tx_start <= '0'; u_div <= to_unsigned(234, 8);
                lcd_start <= '0';
                buz_note <= "000";
                pwm_duty <= (others => '0');
                pwm_settle <= to_unsigned(130, 8);
            else
                ready       <= valid;
                sel_ram     <= not addr(9);
                dbg_we      <= '0';
                dac_we      <= '0';
                u_tx_start  <= '0';
                lcd_start   <= '0';

                if first = '1' then
                    if we = '1' then
                        if addr = A_LED then led_r <= wdata(1 downto 0); end if;
                        if addr = A_DBG then dbg_we <= '1'; dbg_data <= wdata; end if;
                        if addr = A_UDAT then u_tx_data <= wdata; u_tx_start <= '1'; end if;
                        if addr = A_UDIV then u_div <= unsigned(wdata); end if;
                        if addr = A_LCDCMD then lcd_data_in <= wdata; lcd_rs_in <= '0'; lcd_start <= '1'; end if;
                        if addr = A_LCDDATA then lcd_data_in <= wdata; lcd_rs_in <= '1'; lcd_start <= '1'; end if;
                        if addr = A_BUZ then buz_note <= wdata(2 downto 0); end if;
                        if addr = A_DACCTRL then dac_data_in <= wdata(5 downto 0); dac_we <= '1' ; end if;
                        if addr = A_PWM_DUTY then pwm_duty <= unsigned(wdata); end if;
                        if addr = A_PWM_SETTLE then pwm_settle <= unsigned(wdata); end if;
                    elsif addr = A_BTN then
                        io_q   <= "00" & bpress & "00" & bdeb;
                        bp := "00";                         -- clear on read
                    elsif addr = A_KEYBOARD then
                        io_q   <= kpress & kdeb;             -- [7:4] presses, [3:0] level
                        kp := "0000";                        -- clear on read
                    elsif addr = A_LED then
                        io_q <= "000000" & led_r;
                    elsif addr = A_USTA then
                        io_q <= "0000000" & u_tx_busy;
                    elsif addr = A_URXDATA then
                        io_q <= u_rx_byte;
                    elsif addr = A_URXSTAT then
                        io_q <= "000000" & u_rx_error & u_rx_valid;
                    elsif addr = A_LCDSTAT then
                        io_q <= "0000000" & lcd_busy;
                    elsif addr = A_BUZ then
                        io_q <= "00000" & buz_note;
                    elsif addr = A_DACCMP then
                        io_q <= "0000000" & dac_cmp_s;
                    elsif addr = A_PWM_DUTY_STAT then
                        io_q <= "0000000" & pwm_rdy;
                    elsif addr = A_PWM_DUTY then
                        io_q <= std_logic_vector(pwm_duty);
                    elsif addr = A_PWM_SETTLE then
                        io_q <= std_logic_vector(pwm_settle);
                    elsif addr = A_UDIV then
                        io_q <= std_logic_vector(u_div);
                    else
                        io_q <= (others => '0');
                    end if;
                end if;

                -- latch presses until read
                bpress <= bp or brise;
                kpress <= kp or krise;
            end if;
        end if;
    end process;

    rdata <= dq when sel_ram = '1' else io_q;
    led   <= led_r;
    wake  <= bpress(0) or bpress(1);
end architecture;
