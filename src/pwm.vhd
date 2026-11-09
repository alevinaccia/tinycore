library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- PWM ~1 kHz (27 MHz / 104 / 256). Every 16th period EN is forced low (gap)
-- for back-EMF sampling; ready = in gap and settle elapsed.
entity pwm is
    port (
        clk       : in  std_logic;
        duty_in   : in  std_logic_vector(7 downto 0);
        settle_in : in  std_logic_vector(7 downto 0);   -- ticks of 3.85 us
        en        : out std_logic;
        pwr       : out std_logic;
        ready     : out std_logic
    );
end entity;

architecture rtl of pwm is
    signal duty   : std_logic_vector(7 downto 0):= (others => '0');
    signal pre    : unsigned(6 downto 0) := (others => '0');
    signal tick   : std_logic := '0';
    signal cnt    : unsigned(7 downto 0) := (others => '0');
    signal period : unsigned(3 downto 0) := (others => '0');
    signal scnt   : unsigned(7 downto 0) := (others => '0');
    signal gap    : std_logic;
begin
    gap <= '1' when period = 0 else '0';

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
                if cnt = 255 then
                    period <= period + 1;
                end if;
                -- settle timer runs only inside the gap
                if gap = '1' then
                    if scnt /= 255 then scnt <= scnt + 1; end if;
                else
                    scnt <= (others => '0');
                end if;
            end if;

            if gap = '0' and cnt < unsigned(duty) then
                en <= '1';
            else
                en <= '0';
            end if;

            if gap = '1' and scnt >= unsigned(settle_in) then
                ready <= '1';
            else
                ready <= '0';
            end if;
        end if;
    end process;

    pwr <= '1';
end architecture;
