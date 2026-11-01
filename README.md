# sasdr — Direct-Sampling HF SDR Receiver on Tang Nano 9K FPGA

**sasdr** is an open-source, direct-sampling High Frequency (HF) Software-Defined Radio (SDR) receiver implemented in Verilog for the **Sipeed Tang Nano 9K** (Gowin `GW1NR-LV9QN88PC6/I5`) FPGA board.

It captures RF signals directly from a 12-bit high-speed parallel ADC (**AD9226** running at 61.44 MSPS), performs Digital Down-Conversion (DDC) with CIC decimation and droop-compensating FIR filtering, streams 24-bit baseband I/Q samples over **I2S**, and provides **Kenwood CAT** frequency control over USB-UART.

> [!WARNING]
> **Hardware Status (Work in Progress):** The **Tang Nano 9K** FPGA board and hardware components have just been ordered and have **not yet been tested on physical hardware**. So far, the gateware has been verified via Verilator C++ simulations (`sim_sweep.cpp`) and full synthesis/place-and-route (`Yosys` + `nextpnr-himbaechel`).

---

## Key Features

- **Direct RF Sampling**: Interfaces with a 12-bit parallel **AD9226** ADC at a 61.44 MHz system/sampling clock (covering DC to ~30 MHz HF bands).
- **32-bit Numerically Controlled Oscillator (NCO)**: Dual 1024×12-bit sine/cosine Lookup Tables (`sin_lut.hex`, `cos_lut.hex`) providing sub-Hertz tuning resolution ($\Delta f \approx 0.0143\text{ Hz}$).
- **4th-Order CIC Decimator**: Decimates the 61.44 MSPS mixed I/Q stream by $R = 640$ down to a 96 kSPS baseband rate using 54-bit internal accumulators to prevent overflow.
- **21-Tap Compensating FIR (CFIR) Filter**: Symmetric inverse $\text{sinc}^4$ filter implemented with a time-multiplexed Gowin DSP Multiply-Accumulate (MAC) engine to flatten the CIC passband droop.
- **24-bit Stereo I2S Output**: Streams baseband In-phase (`I` on Left channel) and Quadrature (`Q` on Right channel) audio/baseband data at 96 kHz stereo (`CLK_DIV = 5`, 32-bit frames, 24-bit data) for connection to an I2S audio interface or PC soundcard.
- **Kenwood CAT Protocol over UART**: Built-in hardware parser and responder for Kenwood `FA` frequency read/write commands at **115200 baud** over the onboard USB-UART bridge—compatible with standard SDR software (SDR#, HDSDR, Quisk, WSJT-X, Hamlib).
- **100% Open-Source FPGA Flow**: Synthesizes and places-and-routes using **Yosys**, **nextpnr-himbaechel**, **Project Apicula (`gowin_pack`)**, and **openFPGALoader**, with **Verilator** C++ testbenches for frequency-response verification.

---

## Architecture & Signal Processing Pipeline

```
                  61.44 MSPS                               96 kSPS                  96 kSPS                   96 kHz Stereo
AD9226 (12-bit) ────────────► [Offset Bin -> 2's Comp] ──► [Complex Mixer] ──► [4th-Order CIC] ──► [21-Tap CFIR] ──► [I2S TX] ──► I/Q Out
                                                                 ▲                 (R = 640)       (Inv. sinc^4)
                                                                 │ cos / -sin
                                                           [32-bit NCO]
                                                                 ▲
                                                                 │ 32-bit FTW
                                              USB-UART ◄─► [Kenwood CAT]
                                            (115200 8N1)   (FA commands)
```

### Module Hierarchy

| File | Module | Description |
| :--- | :--- | :--- |
| `top_tangnano9k.v` | `top_tangnano9k` | Top-level wrapper for Tang Nano 9K pins, ADC offset-binary to two's complement conversion, and 6-LED level meter (`~i_out[23:18]`). |
| `ddc_top.v` | `ddc_top` | Core DDC pipeline integrating UART CAT control, NCO, complex mixer, dual I/Q CIC decimators, dual CFIR filters, and I2S transmitter. |
| `nco.v` | `nco` | 32-bit phase accumulator with 10-bit phase-to-amplitude LUT addressing (`sin_lut.hex`, `cos_lut.hex`) outputting 12-bit `cos` and `-sin`. |
| `cic_decimator.v` | `cic_decimator` | 4-stage Cascaded Integrator-Comb filter with decimation factor $R = 640$ and 54-bit internal width, outputting 24-bit samples at 96 kSPS. |
| `cfir.v` | `cfir` | 21-tap symmetric FIR filter compensating for CIC passband droop using sequential MAC operations over 21 clock cycles per sample. |
| `i2s_tx.v` | `i2s_tx` | Stereo 24-bit I2S transmitter (`CLK_DIV = 5` for 96 kHz L/R word rate from 61.44 MHz clock). |
| `ddc_cat_kenwood.v` | `ddc_cat_kenwood` | Hardware FSM parsing Kenwood `FA;` and `FAxxxxxxxxxxx;` commands and converting frequency in Hz directly to a 32-bit NCO Frequency Tuning Word (FTW). Defaults to **7.074 MHz** (40m FT8 frequency) on reset. |
| `uart_rx.v` / `uart_tx.v` | `uart_rx`, `uart_tx` | 115200 baud 8N1 UART transceiver clocked at 61.44 MHz. |
| `sim_sweep.cpp` | — | Verilator C++ testbench performing a baseband frequency sweep (1 kHz – 47 kHz) and exporting filter passband response to `sweep_response.csv`. |

---

## Hardware & Pinout (`tangnano9k.cst`)

### Target Hardware
- **FPGA Board**: Sipeed Tang Nano 9K (`GW1NR-LV9QN88PC6/I5`)
- **RF ADC**: AD9226 (12-bit, up to 65 MSPS parallel ADC module)
- **Clock Source**: 61.44 MHz oscillator fed into both the AD9226 clock input and FPGA Pin 52 (`clk`)
- **Audio/I/Q Output**: Standard 3-wire I2S slave receiver / soundcard bridge

### Pin Assignment

| Signal | FPGA Pin | I/O Standard | Description |
| :--- | :---: | :---: | :--- |
| `clk` | `52` | `LVCMOS33` | 61.44 MHz Master / ADC Clock |
| `rst_n` | `3` | `LVCMOS18` | Active-low Reset (Onboard Button S1) |
| `uart_tx_pin` | `17` | `LVCMOS33` | Onboard USB-UART TX (Kenwood CAT) |
| `uart_rx_pin` | `18` | `LVCMOS33` | Onboard USB-UART RX (Kenwood CAT) |
| `i2s_sck_pin` | `25` | `LVCMOS33` | I2S Serial Bit Clock (BCLK) |
| `i2s_ws_pin` | `26` | `LVCMOS33` | I2S Word Select / Left-Right Clock (LRCLK: `0` = I, `1` = Q) |
| `i2s_sd_pin` | `27` | `LVCMOS33` | I2S Serial Data (24-bit MSB-first in 32-bit slot) |
| `adc_data[0..11]` | `28..39` | `LVCMOS33` | 12-bit Parallel Data Bus from AD9226 (`adc_data[0]` = Pin 28 ... `adc_data[11]` = Pin 39) |
| `led[0..5]` | `10,11,13,14,15,16` | `LVCMOS18` | Onboard LEDs (Real-time I-channel signal level indicator) |

---

## Kenwood CAT Control Protocol

The receiver listens on the Tang Nano 9K USB serial port at **115200 baud, 8N1** and implements the Kenwood `FA` (VFO-A Frequency) command set:

- **Read current frequency**:
  - Send: `FA;`
  - Response: `FA00007074000;` (11-digit frequency in Hz, e.g., 7,074,000 Hz = 7.074 MHz)
- **Set new frequency**:
  - Send: `FA00014074000;` (sets VFO-A to 14.074 MHz)
  - Response: `FA00014074000;`

Internally, the FPGA converts the 11-digit ASCII value in Hz ($f_{\text{Hz}}$) to the 32-bit NCO Frequency Tuning Word using fixed-point multiplication:
$$\text{FTW} = \left\lfloor \frac{f_{\text{Hz}} \times 4581278}{2^{16}} \right\rfloor \approx f_{\text{Hz}} \times \frac{2^{32}}{61.44 \times 10^6}$$

---

## Prerequisites & Toolchain

Ensure the following open-source FPGA and simulation tools are installed and available in your `PATH` (e.g., via [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) or Homebrew):

- **Yosys** (`yosys`) — Verilog synthesis
- **nextpnr-himbaechel** (`nextpnr-himbaechel`) — Place and route for Gowin FPGAs
- **Apicula** (`gowin_pack`) — Bitstream generation
- **openFPGALoader** (`openFPGALoader`) — Board programming (SRAM & Flash)
- **Verilator** (`verilator`) & **Clang++** (`clang++`) — Linting and C++ cycle-accurate simulation
- **Surfer** (`surfer`, optional) — Waveform viewer for `.vcd` files

---

## Building, Flashing & Simulation

All build steps are automated via the included `Makefile`:

### 1. Synthesize and Build Bitstream
Runs Yosys synthesis, `nextpnr-himbaechel` place-and-route (constrained to 61.44 MHz), and packs the bitstream into `build/sasdr.fs`:
```bash
make build
```

### 2. Program the Tang Nano 9K
Load the bitstream temporarily into FPGA SRAM (fast, lost on power-off):
```bash
make load
```
Or flash it permanently to onboard SPI Flash:
```bash
make flash
```

### 3. Check Resource Utilization
Run synthesis and print detailed Gowin FPGA resource statistics (LUTs, flip-flops, ALU, BSRAM, DSP macros):
```bash
make stat
```

### 4. Lint Verilog Sources
Run fast static analysis with Verilator:
```bash
make lint
```

### 5. Run Passband Frequency Sweep Simulation
Compile and run the Verilator C++ sweep testbench (`sim_sweep.cpp`) to measure the combined CIC + CFIR frequency response from 1 kHz to 47 kHz and write results to `sweep_response.csv`:
```bash
make sweep
```

### 6. Clean Build Artifacts
```bash
make clean
```

---

## License

Copyright (c) 2026 **Imre Városi ([@sas972](https://github.com/sas972))**

This project is licensed under the **MIT License with the Beer-Ware Clause** — see the [LICENSE](LICENSE) file for details:

> *"As long as you retain this notice you can do whatever you want with this stuff. If we meet some day, and you think this stuff is worth it, you can buy me a beer in return."*

