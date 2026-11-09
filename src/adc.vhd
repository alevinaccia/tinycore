library ieee;
use ieee.numeric_std.all;
use ieee.std_logic_1164.all;

entity adc is 
    generic (
        N : natural := 6
    );
    port (
        clk     : in std_logic;
        we      : in std_logic;
        din     : in std_logic_vector(N - 1 downto 0);
        ctrl    : out std_logic_vector(N - 1  downto 0);
        cmp_in  : in std_logic;
        cmp     : out std_logic
    );
end entity;

architecture rtl of adc is
    signal ctrl_i : std_logic_vector(N - 1 downto 0) := (others => '0');

    -- latch 
    signal s1, s2 : std_logic := '0' ;

begin
    process (clk)
    begin
        if rising_edge(clk) then
            if we = '1' then
                ctrl_i <= din;
            end if;
            s1 <= cmp_in; s2 <= s1;            
        end if;
    end process;
    
    cmp  <= s2;
    ctrl <= ctrl_i;
end architecture;