# ==============================================================================
# Project Configuration (Tang Nano 9K)
# ==============================================================================
PROJ       = sasdr
TOP_MODULE = top_tangnano9k
TB_MODULE  = 
SRCS       = top_tangnano9k.v ddc_top.v nco.v cic_decimator.v cfir.v i2s_tx.v uart_rx.v uart_tx.v ddc_cat_kenwood.v
TB_SRCS    = 
CST        = tangnano9k.cst

# Gowin / Tang Nano 9K Hardware Parameters
DEVICE     = GW1NR-LV9QN88PC6/I5
FAMILY     = GW1N-9C
BOARD      = tangnano9k

# ==============================================================================
# Toolchain Binaries (Auto-resolved from PATH or local venv)
# ==============================================================================
YOSYS          = yosys
NEXTPNR        = nextpnr-himbaechel
GOWIN_PACK    ?= $(shell which gowin_pack 2>/dev/null || echo ./venv/bin/gowin_pack)
OPENFPGALOADER = openFPGALoader

IVERILOG       = iverilog
VVP            = vvp
VERILATOR      = verilator
SURFER         = surfer

# Output build artifacts into a dedicated 'build' directory
BUILD_DIR  = build
SYNTH_JSON = $(BUILD_DIR)/$(PROJ)_synth.json
PNR_JSON   = $(BUILD_DIR)/$(PROJ)_pnr.json
BITSTREAM  = $(BUILD_DIR)/$(PROJ).fs
SIM_OUT    = $(BUILD_DIR)/$(PROJ)_sim.out
VCD_FILE   = dump.vcd

# ==============================================================================
# Two-Phase Verilator Configuration
# ==============================================================================
VERILATOR_DIR   = obj_dir
VERILATOR_ROOT ?= $(shell verilator -getenv VERILATOR_ROOT 2>/dev/null || echo /opt/homebrew/share/verilator)
VCD_VERILATOR   = verilator_dump.vcd

CXX             = clang++
CXXFLAGS        = -std=c++17 -Wall -O2 \
                  -I$(VERILATOR_DIR) \
                  -I$(VERILATOR_ROOT)/include \
                  -I$(VERILATOR_ROOT)/include/vltstd

# Verilator internal runtime sources (required for VCD tracing and simulation)
VLT_SRCS        = $(VERILATOR_ROOT)/include/verilated.cpp \
                  $(VERILATOR_ROOT)/include/verilated_vcd_c.cpp \
                  $(VERILATOR_ROOT)/include/verilated_threads.cpp

GEN_SRCS        = $(wildcard $(VERILATOR_DIR)/V$(TOP_MODULE)*.cpp)

# ==============================================================================
# Build Targets
# ==============================================================================
.PHONY: all build lint sim wave load flash clean help v-headers build-v-sim run-v-sim v-wave v-clean sweep stat

# Phase 1: Generate C++ headers and model classes from Verilog
v-headers:
	$(VERILATOR) -Wno-DECLFILENAME -Wno-PROCASSINIT \
	             --trace -cc $(SRCS) --top-module $(TOP_MODULE) \
	             -GWAIT_TIME=24\'d5

# Phase 2: Compile C++ testbench with native clang++
build-v-sim: $(VERILATOR_DIR)/V$(TOP_MODULE).h sim_main.cpp
	$(CXX) $(CXXFLAGS) sim_main.cpp $(GEN_SRCS) $(VLT_SRCS) \
	      -o $(VERILATOR_DIR)/sim_bin

# Run Verilator simulation and generate waveform
run-v-sim: build-v-sim
	./$(VERILATOR_DIR)/sim_bin

v-wave: run-v-sim
	$(SURFER) $(VCD_VERILATOR) &

all: build

VFLAGS = -Wall \
         -Wno-DECLFILENAME \
         -Wno-PROCASSINIT \
         -Wno-WIDTH \
         -Wno-UNUSEDSIGNAL \
         -Wno-PINCONNECTEMPTY

# 1. Fast syntax and logic check (Verilator Linter)
lint:
	$(VERILATOR) --lint-only $(VFLAGS) $(SRCS) --top-module $(TOP_MODULE)

# 2. Run simulation (Icarus Verilog)
sim: $(VCD_FILE)

$(VCD_FILE): $(SRCS) $(TB_SRCS) | $(BUILD_DIR)
	$(IVERILOG) -o $(SIM_OUT) -s $(TB_MODULE) $(SRCS) $(TB_SRCS)
	$(VVP) $(SIM_OUT)

# 3. Run simulation and open waveform in Surfer
wave: sim
	$(SURFER) $(VCD_FILE) &

# 4. Full physical FPGA build (Yosys -> nextpnr-himbaechel -> gowin_pack)
build: $(BITSTREAM)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(SYNTH_JSON): $(SRCS) | $(BUILD_DIR)
	$(YOSYS) -p "read_verilog $(SRCS); synth_gowin -top $(TOP_MODULE) -json $(SYNTH_JSON)"

$(PNR_JSON): $(SYNTH_JSON) $(CST)
	$(NEXTPNR) --json $(SYNTH_JSON) \
	           --write $(PNR_JSON) \
	           --device $(DEVICE) \
	           --vopt family=$(FAMILY) \
	           --freq 61.44 \
	           --vopt cst=$(CST)

$(BITSTREAM): $(PNR_JSON)
	$(GOWIN_PACK) -d $(FAMILY) -o $(BITSTREAM) $(PNR_JSON)

# 5. Load bitstream into board SRAM (volatile, fast testing)
load: $(BITSTREAM)
	$(OPENFPGALOADER) -b $(BOARD) $(BITSTREAM)

# 6. Flash bitstream into onboard SPI Flash (non-volatile)
flash: $(BITSTREAM)
	$(OPENFPGALOADER) -b $(BOARD) -f $(BITSTREAM)

# 7. Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) $(VCD_FILE) $(VERILATOR_DIR)

v-clean:
	rm -rf $(VERILATOR_DIR)

SWEEP_BIN = $(VERILATOR_DIR)/sim_sweep

sweep: $(SWEEP_BIN)
	./$(SWEEP_BIN)

$(SWEEP_BIN): $(SRCS) sim_sweep.cpp
	$(VERILATOR) -Wno-DECLFILENAME -Wno-PROCASSINIT -Wno-WIDTH \
	             -cc $(SRCS) --top-module ddc_top
	$(CXX) $(CXXFLAGS) sim_sweep.cpp $(VERILATOR_DIR)/Vddc_top*.cpp $(VLT_SRCS) \
	      -o $(SWEEP_BIN)

# Run Yosys synthesis only and print detailed resource utilization statistics
stat: $(SRCS) | $(BUILD_DIR)
	$(YOSYS) -p "read_verilog $(SRCS); synth_gowin -top $(TOP_MODULE) -json $(SYNTH_JSON); stat"
