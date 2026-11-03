#!/usr/bin/env python3
"""TinyCore assembler, RISC-V style syntax -> prog_pkg.vhd

usage: tasm.py prog.s -o prog_pkg.vhd [-l prog.lst]

registers: a (accumulator), b. ALU results always go to a.

  li    a, 5            a = 5
  lb    a, VAR          a = mem[VAR]          lb a, TBL(b)   a = mem[TBL+b]
  sb    a, VAR          mem[VAR] = a          sb a, TBL(b)   mem[TBL+b] = a
  mv    b, a  /  mv a, b
  add   a, a, b         addi  a, a, 5         (also adc/adci = with carry)
  sub   a, a, b         subi  a, a, 5
  and/or/xor a, a, b    andi/ori/xori a, a, 0x0F
  not   a, a            slli/srli/srai a, a, n   (n copies of a 1-bit shift)
  beq/bne/bltu/bgeu a, b|imm, label            (pseudo: cmp + branch)
  beqz/bnez a, label                           (pseudo: cmp #0 + branch)
  bz/bnz/bc/bnc label   raw flag branch on last result
  j label   call label   ret   nop   wfi

directives: .equ NAME, expr  .text  .data  .byte  .ascii  .asciz
comments: # or //
"""
import argparse, re, sys

IMEM, DMEM = 1024, 512


class AsmError(Exception):
    pass


def word(op, x=0, v=0, field=0):
    return (op << 12) | (x << 11) | (v << 10) | (field & 0x3FF)


# --- parsing helpers -------------------------------------------------------

def strip_comment(s):
    out, q = [], None
    i = 0
    while i < len(s):
        ch = s[i]
        if q:
            out.append(ch)
            if ch == "\\" and i + 1 < len(s):
                out.append(s[i + 1]); i += 1
            elif ch == q:
                q = None
        elif ch in "\"'":
            q = ch; out.append(ch)
        elif ch == "#" or s.startswith("//", i):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).strip()


def split_args(s):
    out, cur, q = [], "", None
    for ch in s:
        if q:
            cur += ch
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch; cur += ch
        elif ch == ",":
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def ev(expr, sym, n, need=True):
    e = re.sub(r"'(\\?.)'", lambda m: str(ord(m.group(1).encode().decode("unicode_escape"))),
               expr.strip())
    toks = re.findall(r"0x[0-9a-fA-F]+|0b[01]+|\d+|[A-Za-z_]\w*|[-+*()]", e)
    if not toks or "".join(toks) != e.replace(" ", ""):
        raise AsmError(f"line {n}: bad expression '{expr}'")
    out = []
    for t in toks:
        if re.fullmatch(r"[A-Za-z_]\w*", t):
            if t not in sym:
                if not need:
                    return 0
                raise AsmError(f"line {n}: unknown symbol '{t}'")
            out.append(str(sym[t]))
        else:
            out.append(str(int(t, 0)) if t[0].isdigit() else t)
    return eval("".join(out), {"__builtins__": {}})


def parse_str(s, n):
    m = re.fullmatch(r'"(.*)"', s.strip())
    if not m:
        raise AsmError(f"line {n}: expected \"string\"")
    return list(m.group(1).encode().decode("unicode_escape").encode("latin1"))


# --- instruction encoder ---------------------------------------------------

ALU_REG = {"add": (0x5, 0), "adc": (0x5, 1), "sub": (0x6, 0),
           "and": (0x7, 0), "or": (0x8, 0), "xor": (0x9, 0)}
ALU_IMM = {"adci": (0x5, 1), "subi": (0x6, 0),
           "andi": (0x7, 0), "ori": (0x8, 0), "xori": (0x9, 0)}
SHIFTS = {"slli": (0, 0), "srli": (1, 0), "srai": (1, 1)}   # (V, X)
FLAGB = {"bz": (0, 0), "bc": (1, 0), "bnz": (0, 1), "bnc": (1, 1)}  # (V, X)
CMPB = {"beq": "bz", "bne": "bnz", "bltu": "bc", "bgeu": "bnc"}


def encode(mn, args, sym, n, final):
    """return list of 16-bit words. sizes must not depend on symbol values."""
    def need(k):
        if len(args) != k:
            raise AsmError(f"line {n}: '{mn}' takes {k} operand(s), got {len(args)}")

    def reg(i, want):
        if args[i].lower() != want:
            raise AsmError(f"line {n}: '{mn}' operand {i + 1} must be '{want}' "
                           f"(ALU results always go to a)")

    def val(e):
        return ev(e, sym, n, need=final)

    def imm8(e):
        v = val(e)
        if final and not -128 <= v <= 255:
            raise AsmError(f"line {n}: immediate {v} does not fit in 8 bits")
        return v & 0xFF

    def addr10(e):
        v = val(e)
        if final and not 0 <= v < 1024:
            raise AsmError(f"line {n}: address {v} out of range 0..1023")
        return v

    def cmp_with(src):
        if src.lower() == "b":
            return word(0x6, 0, 1)
        return word(0x6, 1, 1, imm8(src))

    def mem(e):
        m = re.fullmatch(r"(.*)\(\s*(b|zero)\s*\)", e, re.I)
        if m:
            base = m.group(1).strip() or "0"
            return (1 if m.group(2).lower() == "b" else 0), addr10(base)
        return 0, addr10(e)

    if mn == "nop":
        need(0); return [word(0x0)]
    if mn == "wfi":
        need(0); return [word(0xF)]
    if mn == "ret":
        need(0); return [word(0xE, 0, 1)]
    if mn in ("j", "call"):
        need(1); return [word(0xC if mn == "j" else 0xE, 0, 0, addr10(args[0]))]
    if mn == "li":
        need(2)
        if args[0].lower() == "b":
            raise AsmError(f"line {n}: no 'li b' in hardware; use li a, n then mv b, a")
        reg(0, "a"); return [word(0x1, 0, 0, imm8(args[1]))]
    if mn in ("lb", "sb"):
        need(2); reg(0, "a")
        x, ad = mem(args[1])
        return [word(0x2 if mn == "lb" else 0x3, x, 0, ad)]
    if mn == "mv":
        need(2)
        d, s = args[0].lower(), args[1].lower()
        if (d, s) == ("b", "a"):
            return [word(0x4, 0, 0)]
        if (d, s) == ("a", "b"):
            return [word(0x4, 0, 1)]
        raise AsmError(f"line {n}: mv supports only 'mv b, a' and 'mv a, b'")
    if mn in ALU_REG:
        need(3); reg(0, "a"); reg(1, "a"); reg(2, "b")
        op, v = ALU_REG[mn]; return [word(op, 0, v)]
    if mn == "addi":
        need(3); reg(0, "a"); reg(1, "a")
        return [word(0xB, 0, 0, imm8(args[2]))]
    if mn in ALU_IMM:
        need(3); reg(0, "a"); reg(1, "a")
        op, v = ALU_IMM[mn]; return [word(op, 1, v, imm8(args[2]))]
    if mn == "not":
        need(2); reg(0, "a"); reg(1, "a")
        return [word(0x9, 1, 0, 0xFF)]
    if mn in SHIFTS:
        need(3); reg(0, "a"); reg(1, "a")
        k = ev(args[2], sym, n)                   # must be known in pass 1
        if not 1 <= k <= 7:
            raise AsmError(f"line {n}: shift amount must be 1..7")
        v, x = SHIFTS[mn]; return [word(0xA, x, v)] * k
    if mn in FLAGB:
        need(1); v, x = FLAGB[mn]
        return [word(0xD, x, v, addr10(args[0]))]
    if mn in CMPB:
        need(3); reg(0, "a")
        v, x = FLAGB[CMPB[mn]]
        return [cmp_with(args[1]), word(0xD, x, v, addr10(args[2]))]
    if mn in ("beqz", "bnez"):
        need(2); reg(0, "a")
        v, x = FLAGB["bz" if mn == "beqz" else "bnz"]
        return [word(0x6, 1, 1, 0), word(0xD, x, v, addr10(args[1]))]
    if mn in ("blt", "bge", "bgt", "ble"):
        raise AsmError(f"line {n}: signed branches need N/V flags (not in hardware); "
                       f"use bltu/bgeu")
    raise AsmError(f"line {n}: unknown instruction '{mn}'")


# --- assembler -------------------------------------------------------------

def assemble(src):
    lines = []
    for n, raw in enumerate(src.splitlines(), 1):
        code = strip_comment(raw)
        if code:
            lines.append((n, code))

    sym = {}
    for final in (False, True):
        pc = {"text": 0, "data": 0}
        imem, dmem, lst = [0] * IMEM, [0] * DMEM, []
        sec = "text"
        for n, code in lines:
            m = re.match(r"([A-Za-z_]\w*):\s*(.*)", code)
            if m:
                if not final:
                    if m.group(1) in sym:
                        raise AsmError(f"line {n}: duplicate label '{m.group(1)}'")
                    sym[m.group(1)] = pc[sec]
                code = m.group(2)
                if not code:
                    continue
            parts = code.split(None, 1)
            mn = parts[0].lower()
            rest = parts[1] if len(parts) > 1 else ""

            if mn == ".equ":
                if "," not in rest:
                    raise AsmError(f"line {n}: .equ needs 'NAME, value'")
                name, e = [p.strip() for p in rest.split(",", 1)]
                if final is False and name in sym:
                    raise AsmError(f"line {n}: '{name}' already defined")
                sym[name] = ev(e, sym, n)
                continue
            if mn in (".text", ".data"):
                sec = mn[1:]
                continue
            if mn in (".byte", ".ascii", ".asciz"):
                if sec != "data":
                    raise AsmError(f"line {n}: {mn} only allowed in .data")
                if mn == ".byte":
                    vals = [ev(x, sym, n, need=final) for x in split_args(rest)]
                else:
                    vals = parse_str(rest, n) + ([0] if mn == ".asciz" else [])
                for v in vals:
                    if pc["data"] >= DMEM:
                        raise AsmError(f"line {n}: data memory full")
                    dmem[pc["data"]] = v & 0xFF
                    pc["data"] += 1
                continue
            if mn.startswith("."):
                raise AsmError(f"line {n}: unknown directive '{mn}'")
            if sec != "text":
                raise AsmError(f"line {n}: instruction inside .data")

            words = encode(mn, split_args(rest), sym, n, final)
            for i, w in enumerate(words):
                if pc["text"] >= IMEM:
                    raise AsmError(f"line {n}: program memory full")
                imem[pc["text"]] = w
                lst.append(f"{pc['text']:03X}  {w:04X}  {code if i == 0 else '  (cont.)'}")
                pc["text"] += 1
    return imem, dmem, lst, pc


def vhdl(imem, dmem):
    def arr(vals, w):
        return ",\n".join("        " + ", ".join(f'x"{v:0{w}X}"' for v in vals[i:i + 8])
                          for i in range(0, len(vals), 8))
    return f"""-- generated by tasm.py, do not edit
library ieee;
use ieee.std_logic_1164.all;

package prog_pkg is
    type imem_t is array (0 to {IMEM - 1}) of std_logic_vector(15 downto 0);
    type dmem_t is array (0 to {DMEM - 1}) of std_logic_vector(7 downto 0);
    constant IMEM_INIT : imem_t := (
{arr(imem, 4)}
    );
    constant DMEM_INIT : dmem_t := (
{arr(dmem, 2)}
    );
end package;
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("-o", default="prog_pkg.vhd")
    ap.add_argument("-l", help="listing file")
    a = ap.parse_args()
    try:
        imem, dmem, lst, pc = assemble(open(a.src).read())
    except AsmError as e:
        sys.exit(f"{a.src}: {e}")
    out = vhdl(imem, dmem)
    try:
        same = open(a.o).read() == out
    except OSError:
        same = False
    if not same:                      # keep mtime so make skips resynthesis
        open(a.o, "w").write(out)
    if a.l:
        open(a.l, "w").write("\n".join(lst) + "\n")
    print(f"{a.src}: {pc['text']} words, {pc['data']} data bytes -> {a.o}")


if __name__ == "__main__":
    main()
