-- uart 8N1
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- uart tx peripheral
-- div controls the baud rate 
-- the fpga has a 27MHz Clock and we aim at a 115200 Baud so we need to count to 234 for each bit
-- this gives us a bit time of around 8 microseconds

-- the uart has an internal shift register that sends one bit each time the counter reaches zero
-- we use a 8N1 with NRZ encoding, so we need 1 start bit, 1 end bit and 8 are data -> 10 bits
entity uart_tx is
    port(
        clk, rst: in std_logic;
        div     : in unsigned(7 downto 0);
        data    : in std_logic_vector(7 downto 0);
        start   : in std_logic;
        busy    : out std_logic;
        tx      : out std_logic
    );
end entity;

architecture rtl of uart_tx is
    signal sh : STD_LOGIC_VECTOR(9 downto 0) := (others => '1'); --register loaded with [start, data, end]
    signal nbit : natural range 0 to 10 := 0; -- sent bits so far
    signal cnt : UNSIGNED(7 downto 0) := (others => '0');
begin
    busy <= '1' when nbit /= 0 else '0';
    tx <= sh(0);

    process (clk)
    begin
        if(rising_edge(clk)) then
            if rst = '1' then
                sh <= (others => '1'); nbit <= 0; cnt <= (others => '0');
            elsif nbit = 0 then
                if start = '1' then
                    sh <= '1' & data & '0'; -- load register
                    nbit <= 10;             -- set bits to send
                    cnt <= div - 1;         -- set counter
                end if;
            elsif cnt = 0 then              -- time to send next bit
                sh <= '1' & sh(9 downto 1); -- shift
                nbit <= nbit - 1;           -- one bit has been sent
                cnt <= div - 1;             -- reset counter
            else 
                cnt <= cnt - 1;             -- decrement counter
            end if;
        end if;
    end process;

end architecture;
