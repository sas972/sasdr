# ==============================================================================
# Projekt konfiguráció (Tang Nano 9K)
# ==============================================================================
PROJ      = sasdr
TOP_MODULE = top_tangnano9k
TB_MODULE  = 
SRCS       = top_tangnano9k.v ddc_top.v nco.v cic_decimator.v cfir.v i2s_tx.v uart_rx.v uart_tx.v ddc_cat_kenwood.v
TB_SRCS   = 
CST       = tangnano9k.cst

# Gowin / Tang Nano 9K hardver paraméterek
DEVICE    = GW1NR-LV9QN88PC6/I5
FAMILY    = GW1N-9C
BOARD     = tangnano9k

# ==============================================================================
# Toolchain binárisok (Automatikus feloldás: PATH vagy a saját build mappád)
# ==============================================================================
YOSYS          = yosys
NEXTPNR        = nextpnr-himbaechel
GOWIN_PACK    ?= $(shell which gowin_pack 2>/dev/null || echo ./venv/bin/gowin_pack)
OPENFPGALOADER = openFPGALoader

IVERILOG       = iverilog
VVP            = vvp
VERILATOR      = verilator
SURFER         = surfer

# Generált fájlok külön 'build' almappába, hogy tiszta maradjon a projekt
BUILD_DIR = build
SYNTH_JSON = $(BUILD_DIR)/$(PROJ)_synth.json
PNR_JSON   = $(BUILD_DIR)/$(PROJ)_pnr.json
BITSTREAM  = $(BUILD_DIR)/$(PROJ).fs
SIM_OUT    = $(BUILD_DIR)/$(PROJ)_sim.out
VCD_FILE   = dump.vcd



# ==============================================================================
# Kétfázisú Verilator konfiguráció
# ==============================================================================
VERILATOR_DIR   = obj_dir
VERILATOR_ROOT ?= $(shell verilator -getenv VERILATOR_ROOT 2>/dev/null || echo /opt/homebrew/share/verilator)
VCD_VERILATOR = verilator_dump.vcd

CXX             = clang++
CXXFLAGS        = -std=c++17 -Wall -O2 \
                  -I$(VERILATOR_DIR) \
                  -I$(VERILATOR_ROOT)/include \
                  -I$(VERILATOR_ROOT)/include/vltstd

# A Verilator belső runtime forrásfájljai (ezek kellenek a VCD trace-hez és szimulációhoz)
VLT_SRCS        = $(VERILATOR_ROOT)/include/verilated.cpp \
                  $(VERILATOR_ROOT)/include/verilated_vcd_c.cpp \
                  $(VERILATOR_ROOT)/include/verilated_threads.cpp

GEN_SRCS        = $(wildcard $(VERILATOR_DIR)/V$(TOP_MODULE)*.cpp)

# ==============================================================================
# CÉLOK (Targets)
# ==============================================================================
.PHONY: all build lint sim wave load flash clean help v-header build-v-sim run-v-sim v-wave v-clean sweep

# 1. FÁZIS: Csak a C++ headerek és osztályok generálása Verilogból
v-headers:
	$(VERILATOR) -Wno-DECLFILENAME -Wno-PROCASSINIT \
	             --trace -cc $(SRCS) --top-module $(TOP_MODULE) \
	             -GWAIT_TIME=24\'d5

# 2. FÁZIS: A C++ tesztkörnyezet lefordítása natív clang++-szal
build-v-sim: $(VERILATOR_DIR)/V$(TOP_MODULE).h sim_main.cpp
	$(CXX) $(CXXFLAGS) sim_main.cpp $(GEN_SRCS) $(VLT_SRCS) \
	      -o $(VERILATOR_DIR)/sim_bin

# Futtatás és hullámforma készítés
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

# 1. Gyors szintaktikai és logikai ellenőrzés (Verilator Linter)
lint:
	$(VERILATOR) --lint-only $(VFLAGS) $(SRCS) --top-module $(TOP_MODULE)

# 2. Szimuláció futtatása (Icarus Verilog)
sim: $(VCD_FILE)

$(VCD_FILE): $(SRCS) $(TB_SRCS) | $(BUILD_DIR)
	$(IVERILOG) -o $(SIM_OUT) -s $(TB_MODULE) $(SRCS) $(TB_SRCS)
	$(VVP) $(SIM_OUT)

# 3. Szimuláció + Hullámforma megnyitása Surferben
wave: sim
	$(SURFER) $(VCD_FILE) &

# 4. Teljes fizikai fordítás (Yosys -> nextpnr-himbaechel -> gowin_pack)
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

# 5. Feltöltés a kártya SRAM-jába (Gyors tesztelés, áramtalanításig marad meg)
load: $(BITSTREAM)
	$(OPENFPGALOADER) -b $(BOARD) $(BITSTREAM)

# 6. Beégetés a kártya Flash memóriájába (Áramtalanítás után is megmarad)
flash: $(BITSTREAM)
	$(OPENFPGALOADER) -b $(BOARD) -f $(BITSTREAM)

# 7. Takarítás
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


# Csak a Yosys szintézis és a részletes erőforrás-táblázat kiírása
stat: $(SRCS) | $(BUILD_DIR)
	$(YOSYS) -p "read_verilog $(SRCS); synth_gowin -top $(TOP_MODULE) -json $(SYNTH_JSON); stat"