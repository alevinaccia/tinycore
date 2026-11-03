# Tang Nano 20K: ghdl -> yosys -> nextpnr -> apicula; sim with nvc

# design (all src/*.vhd; ghdl resolves order)
TOP    := top
CST    := tangnano20k.cst

# sim (make sim TB=tb_foo)
TB     := tb_soc
STOP   := 100us

# board
DEVICE := GW2AR-LV18QN88C8/I7
FAMILY := GW2A-18C
BOARD  := tangnano20k
# MHz, timing target
FREQ   := 27
BUILD  := build

SRC  := $(wildcard src/*.vhd)
TBS  := $(wildcard tb/*.vhd)
GHDL := ghdl
NVC  := nvc --std=2008 --work=work:$(BUILD)/work
VLOG := $(BUILD)/$(TOP).v
JSON := $(BUILD)/$(TOP).json
PNR  := $(BUILD)/$(TOP)_pnr.json
FS   := $(BUILD)/$(TOP).fs
WAVE := $(BUILD)/$(TB).fst

.PHONY: all build prog flash sim clean
.DELETE_ON_ERROR:

all build: $(FS)

# via verilog: yosys ghdl plugin crashes on designs with >1 input
$(VLOG): $(SRC) Makefile
	@rm -rf $(BUILD)/syn && mkdir -p $(BUILD)/syn
	@$(GHDL) -i --std=08 --workdir=$(BUILD)/syn $(SRC)
	$(GHDL) synth --std=08 --out=verilog \
	  $$($(GHDL) --elab-order --std=08 --workdir=$(BUILD)/syn $(TOP)) -e $(TOP) > $@

$(JSON): $(VLOG)
	yosys -q -l $(BUILD)/yosys.log -p "read_verilog $<; synth_gowin -top $(TOP) -json $@"

$(PNR): $(JSON) $(CST)
	nextpnr-himbaechel -q -l $(BUILD)/pnr.log --json $< --write $@ \
	  --device $(DEVICE) --vopt family=$(FAMILY) --vopt cst=$(CST) --freq $(FREQ)

$(FS): $(PNR)
	gowin_pack -d $(FAMILY) -o $@ $<

# SRAM, lost on power-off
prog: $(FS)
	openFPGALoader -b $(BOARD) $<

# SPI flash, persistent
flash: $(FS)
	openFPGALoader -b $(BOARD) -f $<

sim: $(WAVE)

$(WAVE): $(SRC) $(TBS) Makefile
	@rm -rf $(BUILD)/sim && mkdir -p $(BUILD)/sim
	@$(GHDL) -i --std=08 --workdir=$(BUILD)/sim $(SRC) $(TBS)
	@$(GHDL) --elab-order --std=08 --workdir=$(BUILD)/sim $(TB) > $(BUILD)/sim/order \
	  || { echo "error: testbench '$(TB)' missing from tb/ or has errors (make sim TB=...)"; exit 1; }
	$(NVC) -a $$(cat $(BUILD)/sim/order) -e $(TB) -r --stop-time=$(STOP) --wave=$@

clean:
	rm -rf $(BUILD)
