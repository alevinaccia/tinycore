-- TinyCore: 8-bit A/B, 16-bit instr, Harvard, multicycle.
-- instr: [15:12] op | [11] X | [10] V | [9:0] addr/imm
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tinycore is
    port (
        clk, rst : in  std_logic;
        ce       : in  std_logic;                 -- clock enable (ECO / gating)
        -- instruction port (sync BRAM, 1-cycle read)
        iaddr    : out unsigned(9 downto 0);
        idata    : in  std_logic_vector(15 downto 0);
        -- data bus, valid/ready
        addr     : out unsigned(9 downto 0);
        wdata    : out std_logic_vector(7 downto 0);
        we       : out std_logic;
        valid    : out std_logic;
        rdata    : in  std_logic_vector(7 downto 0);
        ready    : in  std_logic;
        -- WFI
        wake     : in  std_logic;
        sleeping : out std_logic
    );
end entity;

architecture rtl of tinycore is
    type state_t is (FETCH, DECODE, EXEC, MEM, SLEEP);
    type stack_t is array (0 to 3) of unsigned(9 downto 0);

    signal stage    : state_t := FETCH;
    signal pc    : unsigned(9 downto 0) := (others => '0');
    signal ir    : std_logic_vector(15 downto 0) := (others => '0');
    signal a, b  : unsigned(7 downto 0) := (others => '0');
    signal z, c  : std_logic := '0';
    signal stk   : stack_t := (others => (others => '0'));
    signal sp    : unsigned(1 downto 0) := (others => '0');
    signal valid_r, we_r : std_logic := '0';
    signal addr_r : unsigned(9 downto 0) := (others => '0');
    signal wdata_r : std_logic_vector(7 downto 0) := (others => '0');

    -- decode fields of the word coming out of instruction memory (used in DECODE)
    signal d_op : unsigned(3 downto 0);
    signal d_x  : std_logic;
    signal d_ea : unsigned(9 downto 0);

    -- fields of the latched instruction (used in EXEC)
    signal op   : unsigned(3 downto 0);
    signal x, v : std_logic;
    signal a10  : unsigned(9 downto 0);
    signal imm  : unsigned(7 downto 0);
    signal opnd : unsigned(7 downto 0);
begin
    d_op <= unsigned(idata(15 downto 12));  -- extract opcode
    d_x  <= idata(11);                      -- extract x
    d_ea <= unsigned(idata(9 downto 0)) + resize(b, 10) when d_x = '1'
            else unsigned(idata(9 downto 0));-- extract effective address

    op   <= unsigned(ir(15 downto 12));
    x    <= ir(11);
    v    <= ir(10);
    a10  <= unsigned(ir(9 downto 0));
    imm  <= unsigned(ir(7 downto 0));
    opnd <= imm when x = '1' else b;   -- ALU ops 5..9: X selects imm8 over B

    iaddr    <= pc;
    addr     <= addr_r;
    wdata    <= wdata_r;
    we       <= we_r;
    valid    <= valid_r;
    sleeping <= '1' when stage = SLEEP else '0';

    process (clk)
        variable r9  : unsigned(8 downto 0); -- not cr9 but the result stored on 9 bits (usefull so set flags)
        variable res : unsigned(7 downto 0);
        variable tk  : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                stage <= FETCH; pc <= (others => '0'); sp <= (others => '0');
                a <= (others => '0'); b <= (others => '0');
                z <= '0'; c <= '0'; valid_r <= '0'; we_r <= '0';
            elsif ce = '1' then
                case stage is
                when FETCH =>          -- imem latches word at pc
                    stage <= DECODE;

                when DECODE =>
                    ir <= idata;
                    pc <= pc + 1;
                    if d_op = 2 or d_op = 3 then          -- LD / ST: start bus now
                        addr_r  <= d_ea;
                        wdata_r <= std_logic_vector(a);
                        we_r    <= '1' when d_op = 3 else '0';
                        valid_r <= '1';
                        stage <= MEM;
                    else
                        stage <= EXEC;
                    end if;

                when MEM =>
                    if ready = '1' then
                        valid_r <= '0'; we_r <= '0';
                        if op = 2 then
                            a <= unsigned(rdata);
                            z <= '1' when rdata = x"00" else '0';
                        end if;
                        stage <= FETCH;
                    end if;

                when EXEC =>
                    stage <= FETCH;
                    case to_integer(op) is
                    when 1 =>                                  -- li a, opnd
                        a <= imm;
                        z <= '1' when imm = 0 else '0';
                    when 4 =>                                  -- mv a,b | mv b, a
                        if v = '0' then b <= a;
                        else a <= b; z <= '1' when b = 0 else '0';
                        end if;
                    when 5 | 11 =>                             -- ADD/ADC, ADDI
                        if op = 11 then r9 := ('0' & a) + ('0' & imm);
                        else r9 := ('0' & a) + ('0' & opnd) + ("00000000" & (v and c));
                        end if;
                        a <= r9(7 downto 0); c <= r9(8);
                        z <= '1' when r9(7 downto 0) = 0 else '0';
                    when 6 =>                                  -- SUB / CMP, C = borrow
                        r9 := ('0' & a) - ('0' & opnd);
                        if v = '0' then a <= r9(7 downto 0); end if;
                        c <= r9(8);
                        z <= '1' when r9(7 downto 0) = 0 else '0';
                    when 7 | 8 | 9 =>                          -- AND / OR / XOR
                        if    op = 7 then res := a and opnd;
                        elsif op = 8 then res := a or  opnd;
                        else              res := a xor opnd;
                        end if;
                        a <= res;
                        z <= '1' when res = 0 else '0';
                    when 10 =>                                 -- SHL / SHR / ASR
                        if v = '0' then
                            res := a(6 downto 0) & '0'; c <= a(7);
                        else
                            res := (a(7) and x) & a(7 downto 1); c <= a(0);
                        end if;
                        a <= res;
                        z <= '1' when res = 0 else '0';
                    when 12 =>                                 -- JMP
                        pc <= a10;
                    when 13 =>                                 -- Jcc: V=C?Z, X negates
                        if v = '0' then tk := z; else tk := c; end if;
                        tk := tk xor x;
                        if tk = '1' then pc <= a10; end if;
                    when 14 =>                                 -- CALL / RET
                        if v = '0' then
                            stk(to_integer(sp)) <= pc; sp <= sp + 1; pc <= a10;
                        else
                            pc <= stk(to_integer(sp - 1)); sp <= sp - 1;
                        end if;
                    when 15 =>                                 -- WFI
                        stage <= SLEEP;
                    when others => null;                       -- NOP
                    end case;

                when SLEEP =>
                    if wake = '1' then stage <= FETCH; end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
