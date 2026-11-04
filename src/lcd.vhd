-- LCD
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity lcd is 
    generic ( CLK_HZ : natural := 27_000_000);
    port(
        clk         : in std_logic;
        reset_in    : in std_logic;
        rs_in       : in std_logic;
        start       : in std_logic;
        data_in     : in std_logic_vector(7 downto 0);
        busy        : out std_logic := '1';
        lcd_rs      : out std_logic := '0';
        lcd_en      : out std_logic := '0';
        lcd_data    : out std_logic_vector(3 downto 0) := "0000"
    );
end entity;

architecture rtl of lcd is 
    function us_to_cycles(us: natural) return natural is
    begin return (CLK_HZ / 1_000_000) * us;
    end function;

    constant T_40MS : natural := us_to_cycles(40_000);
    constant T_CLEAR : natural := us_to_cycles(1_500);
    constant T_1US  : natural := us_to_cycles(1);
    constant T_40US  : natural := us_to_cycles(40);

    type state_lcd is (LOAD, IDLE, ENABLE_HI, ENABLE_LOW);

    signal state : state_lcd := LOAD;
    signal is_reset : std_logic := '1';
    signal nibble_stage : std_logic := '0';
    signal cnt   : natural range 0 to T_40MS := T_40MS;

    type step_t is record
        rs  : std_logic;
        d   : std_logic_vector(3 downto 0);
        dly : natural;  -- cycles after E falls
    end record;
    type rom_t is array (natural range <>) of step_t;
 
    constant INIT_ROM : rom_t := (
    ('0', b"0011", us_to_cycles(4_100)),
    ('0', b"0011", us_to_cycles(100)),
    ('0', b"0011", us_to_cycles(100)),
    ('0', b"0010", us_to_cycles(100)),                          -- 4-bit
    ('0', b"0010", T_1US), ('0', b"1000", T_40US),    -- 0x28: 2 lines
    ('0', b"0000", T_1US), ('0', b"1100", T_40US),    -- 0x0C: display on
    ('0', b"0000", T_1US), ('0', b"0001", us_to_cycles(2_000)) -- 0x01: clear
    );
    signal step : natural range 0 to INIT_ROM'high := 0; --steps from 0 to length of the init_rom

begin
    process (clk)
    begin
        if(rising_edge(clk)) then
            if reset_in = '1' and is_reset /= '1' then
                is_reset <= '1';
                cnt <= T_40MS;
                step <= 0;
                state <= LOAD;

            elsif cnt /= 0 then
                cnt <= cnt - 1;
            else
            case state is
                when LOAD =>
                    busy <= '1';
                    if is_reset = '1' then
                        lcd_rs <= INIT_ROM(step).rs;
                        lcd_data <= INIT_ROM(step).d;
                    else 
                        lcd_rs <= rs_in;
                        if nibble_stage = '0' then
                            lcd_data <= data_in(7 downto 4);
                        else
                            lcd_data <= data_in(3 downto 0);
                        end if;
                    end if;
                    cnt <= T_1US;
                    state <= ENABLE_HI;
                
                when ENABLE_HI => 
                    lcd_en <= '1';
                    cnt <= T_1US;
                    state <= ENABLE_LOW;

                when ENABLE_LOW =>
                    lcd_en <= '0';
                    if is_reset = '1' then
                        cnt <= INIT_ROM(step).dly;
                        if step = INIT_ROM'high then
                            state <= IDLE;
                            is_reset <= '0';
                        else 
                            step <= step + 1;
                            state <= LOAD;
                        end if;
                    else
                        nibble_stage <= '1';
                        if nibble_stage = '0' then
                            cnt <= T_1US;
                            state <= LOAD;
                        else 
                            cnt <= T_CLEAR when lcd_rs = '0' else T_40US;   -- cmds may be clear/home (1.52 ms)
                            state <= IDLE;
                            nibble_stage <= '0';
                        end if;
                    end if;
                
                when IDLE =>
                    busy <= '0';
                    if start = '1' then
                        state <= LOAD;
                    end if;
            end case;
            end if;
        end if;
    end process;

end architecture;
