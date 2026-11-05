-- N-bit debouncer: 2-FF sync, sample every CYCLES, 1-cycle rise pulse
library ieee;
use ieee.std_logic_1164.all;

entity debounce is
    generic (
        WIDTH  : positive := 1;
        CYCLES : positive := 270000     -- 10 ms @ 27 MHz
    );
    port (
        clk, rst : in  std_logic;
        din      : in  std_logic_vector(WIDTH - 1 downto 0);  -- raw, active high
        q        : out std_logic_vector(WIDTH - 1 downto 0);  -- debounced level
        rise     : out std_logic_vector(WIDTH - 1 downto 0)   -- press pulse
    );
end entity;

architecture rtl of debounce is
    signal s0, s1, st : std_logic_vector(WIDTH - 1 downto 0) := (others => '0');
    signal cnt        : natural range 0 to CYCLES - 1 := 0;
begin
    process (clk) begin
        if rising_edge(clk) then
            s0 <= din; s1 <= s0;
            rise <= (others => '0');
            if rst = '1' then
                st <= (others => '0'); cnt <= 0;
            elsif cnt = CYCLES - 1 then
                cnt  <= 0;
                st   <= s1;
                rise <= s1 and not st;
            else
                cnt <= cnt + 1;
            end if;
        end if;
    end process;
    q <= st;
end architecture;
