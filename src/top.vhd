-- Tang Nano 20K top: 27 MHz
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
    port (
        -- board
        clk         : in  std_logic;
        s1          : in  std_logic;
        s2          : in  std_logic;
        led         : out std_logic_vector(1 downto 0);

        -- peripherals
        keyboard    : in  std_logic_vector(3 downto 0);

        -- uart
        uart_tx     : out std_logic;

        -- lcd
        lcd_rs      : out std_logic;
        lcd_en      : out std_logic;
        lcd_data    : out std_logic_vector(3 downto 0);

        -- buzzer
        buzz        : out std_logic;

        -- pwm controller
        pwm_pwr     : out std_logic;
        pwm_en      : out std_logic;

        -- adc (comparator + 2-2R)
        dac_ctrl    : out std_logic_vector(5 downto 0);
        adc_cmp     : in  std_logic
    );
end entity;

architecture rtl of top is
    signal por  : unsigned(7 downto 0) := (others => '0');
    signal rst  : std_logic;
    signal btn  : std_logic_vector(1 downto 0);
    signal ledi : std_logic_vector(1 downto 0);
    signal slp  : std_logic;
begin
    -- power-on reset, 255 cycles
    -- wait for everything to settle before reset
    process (clk) begin
        if rising_edge(clk) then
            if por /= 255 then por <= por + 1; end if;
        end if;
    end process;
    rst <= '1' when por /= 255 else '0';

    btn <= s2 & s1;

    u_soc : entity work.soc
        port map (
            clk => clk,
            rst => rst,
            btn => btn,
            keyboard => keyboard,
            led => ledi,
            uart_tx => uart_tx,
            lcd_rs => lcd_rs,
            lcd_data => lcd_data,
            lcd_en => lcd_en,
            buzz => buzz,
            dbg_we => open, dbg_data => open,
            sleeping => slp,
            pwm_pwr => pwm_pwr,
            pwm_en   => pwm_en,
            dac_ctrl => dac_ctrl,
            adc_cmp  => adc_cmp
        );

    led <= not ledi; -- leds are active low, thus we invert
end architecture;
