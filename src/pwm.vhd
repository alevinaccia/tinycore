library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- PWM ~1 kHz (27 MHz / 104 / 256)
entity pwm is
    port (
        clk       : in  std_logic;
        duty_in   : in  std_logic_vector(7 downto 0);
        en        : out std_logic;
        pwr       : out std_logic
    );
end entity;

architecture rtl of pwm is
    signal duty   : std_logic_vector(7 downto 0):= (others => '0');
    signal pre    : unsigned(6 downto 0) := (others => '0');
    signal tick   : std_logic := '0';
    signal cnt    : unsigned(7 downto 0) := (others => '0');
begin
    process (clk)
    begin
        if rising_edge(clk) then
            tick <= '0';
            if cnt = 0 then
                duty <= duty_in;
            end if;
            if pre = 103 then
                pre  <= (others => '0');
                tick <= '1';
            else
                pre <= pre + 1;
            end if;

            if tick = '1' then
                cnt <= cnt + 1;
            end if;

            if cnt < unsigned(duty) then
                en <= '1';
            else
                en <= '0';
            end if;
        end if;
    end process;

    pwr <= '1';
end architecture;
