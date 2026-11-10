library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    port (
        clk         : in std_logic;
        data_in     : in std_logic;
        div         : in unsigned(7 downto 0);
        valid       : out std_logic;
        err         : out std_logic;
        rx_byte     : out std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of uart_rx is
    type state_rx is (IDLE, START, DATA, STOP);

    signal state : state_rx := IDLE;
    signal saved_bits : natural range 0 to 8 := 0;
    signal s1, s2 : std_logic := '1'; -- latch
    signal stream : std_logic_vector(7 downto 0) := (others => '0');

    -- counter ctrl
    signal cnt : unsigned(7 downto 0) := (others => '0');
    signal enable : std_logic := '0';
begin

    process(clk)
    begin
        if rising_edge(clk) then
            valid <= '0';
            err   <= '0';
            if enable = '1' then
                cnt <= cnt + 1;
            end if;

            s1 <= data_in; s2 <= s1; -- latch data_in into s2
            case state is
            when IDLE => 
                if s2 = '0' then
                    state <= START;
                    enable <= '1';
                    cnt <= (others => '0');
                end if;
            when START => 
                if cnt >= UNSIGNED(div) / 2 then  
                    state <= DATA when s2 = '0' else IDLE;
                    enable <= '1' when s2 = '0' else '0';
                    cnt <= (others => '0');
                end if;
            when DATA => 
                if saved_bits > 7 then
                    state <= STOP; 
                elsif unsigned(cnt) >= unsigned(div) - 1 then
                    stream <= s2 & stream(7 downto 1);
                    cnt <= (others => '0');
                    saved_bits <= saved_bits + 1;
                end if;
            when STOP => 
                if unsigned(cnt) >= unsigned(div) - 1 then  
                    saved_bits <= 0;
                    state <= IDLE;
                    enable <= '0';
                    cnt <= (others => '0');

                    stream <= (others => '0');
                    rx_byte <= stream when s2 = '1' else (others => '0') ;
                    valid <= '1' when s2 = '1' else '0';
                    err   <= '1' when s2 = '0' else '0';
                end if;
            end case;
        end if;
    end process;
    

end architecture;
