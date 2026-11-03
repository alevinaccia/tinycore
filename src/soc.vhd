-- TinyCore SoC: core + IMEM 1Kx16 + DMEM 512x8 + MMIO peripherals + debug port
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.prog_pkg.all;

entity soc is
    port (
        clk, rst : in  std_logic;
        btn      : in  std_logic_vector(1 downto 0);  -- active high
        led      : out std_logic_vector(1 downto 0);  -- active high
        uart_tx  : out std_logic;
        sleeping : out std_logic;

        -- debug bus
        dbg_we   : out std_logic;                     -- write to 0x3FF (sim)
        dbg_data : out std_logic_vector(7 downto 0)
    );
end entity;

architecture rtl of soc is
    -- MMIO from 0x200 to 0x3FF, used only from 0x300
    constant A_LED           : unsigned(9 downto 0) := to_unsigned(16#300#, 10);
    constant A_BTN           : unsigned(9 downto 0) := to_unsigned(16#301#, 10);
    constant A_UDAT          : unsigned(9 downto 0) := to_unsigned(16#319#, 10);
    constant A_USTA          : unsigned(9 downto 0) := to_unsigned(16#31A#, 10);  -- bit0 = uart busy
    constant A_UDIV          : unsigned(9 downto 0) := to_unsigned(16#31B#, 10);

    constant A_DBG : unsigned(9 downto 0) := to_unsigned(16#3FF#, 10);

    signal imem : imem_t := IMEM_INIT;
    signal dmem : dmem_t := DMEM_INIT;

    signal iaddr          : unsigned(9 downto 0);
    signal idata          : std_logic_vector(15 downto 0) := (others => '0');
    signal addr           : unsigned(9 downto 0);
    signal wdata, rdata   : std_logic_vector(7 downto 0) := (others => '0');
    signal dq             : std_logic_vector(7 downto 0) := (others => '0');
    signal we, valid      : std_logic;
    signal ready          : std_logic := '0';
    signal sel_ram        : std_logic := '0';
    signal io_q           : std_logic_vector(7 downto 0) := (others => '0');

    signal led_r          : std_logic_vector(1 downto 0) := (others => '0');
    signal wake           : std_logic;

    signal u_div          : unsigned(7 downto 0) := to_unsigned(0, 8);
    signal u_tx_data      : std_logic_vector(7 downto 0) := (others => '0');
    signal u_tx_start, u_tx_busy : std_logic := '0';

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
    begin
        if rising_edge(clk) then
            if rst = '1' then
                ready <= '0'; led_r <= (others => '0'); dbg_we <= '0';
                u_tx_start <= '0'; u_div <= to_unsigned(234, 8);
            else
                ready       <= valid;
                sel_ram     <= not addr(9);
                dbg_we      <= '0';
                u_tx_start  <= '0';

                if first = '1' then
                    if we = '1' then
                        if addr = A_LED then led_r <= wdata(1 downto 0); end if;
                        if addr = A_DBG then dbg_we <= '1'; dbg_data <= wdata; end if;
                        if addr = A_UDAT then u_tx_data <= wdata; u_tx_start <= '1'; end if;
                        if addr = A_UDIV then u_div <= unsigned(wdata); end if;
                    elsif addr = A_BTN then
                        io_q   <= "000000" & btn;
                    elsif addr = A_LED then
                        io_q <= "000000" & led_r;
                    elsif addr = A_USTA then
                        io_q <= "0000000" & u_tx_busy;
                    elsif addr = A_UDIV then
                        io_q <= std_logic_vector(u_div);
                    else
                        io_q <= (others => '0');
                    end if;
                end if;

            end if;
        end if;
    end process;

    rdata <= dq when sel_ram = '1' else io_q;
    led   <= led_r;
    wake  <= btn(0) or btn(1);
end architecture;
