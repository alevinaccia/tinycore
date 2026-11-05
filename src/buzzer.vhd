-- Buzzer: square wave, note 0 = off, 1..7 = C6..B6
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity buzzer is
    generic (CLK_HZ : natural := 27_000_000);
    port (
        clk, rst : in  std_logic;
        note     : in  std_logic_vector(2 downto 0);
        pin      : out std_logic
    );
end entity;

architecture rtl of buzzer is
    -- note freq in 0.1 Hz
    type f_tab_t is array (1 to 7) of natural;
    constant F10 : f_tab_t := (10465, 11747, 13185, 13969, 15680, 17600, 19755);

    -- half period in clk cycles
    type n_tab_t is array (0 to 7) of natural range 0 to 65535;
    function mk_tab return n_tab_t is
        variable t : n_tab_t := (others => 0);
    begin
        for i in 1 to 7 loop t(i) := (CLK_HZ * 5) / F10(i); end loop;
        return t;
    end function;
    constant HALF : n_tab_t := mk_tab;

    signal cnt   : natural range 0 to 65535 := 0;
    signal tgl   : std_logic := '0';
    signal prev  : std_logic_vector(2 downto 0) := "000";
begin
    process (clk)
        variable n : natural range 0 to 65535;
    begin
        if rising_edge(clk) then
            n := HALF(to_integer(unsigned(note)));
            prev <= note;
            if rst = '1' or n = 0 or note /= prev then
                cnt <= 0; tgl <= '0';
            elsif cnt >= n - 1 then
                cnt <= 0; tgl <= not tgl;
            else
                cnt <= cnt + 1;
            end if;
        end if;
    end process;

    pin <= tgl;
end architecture;
