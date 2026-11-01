#include <iostream>
#include <fstream>
#include <cmath>
#include <memory>
#include <vector>
#include <algorithm>

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vddc_top.h"

// Verilator simulation time callback
vluint64_t main_time = 0;
double sc_time_stamp() {
    return main_time;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(false); // Disable VCD trace generation for maximum simulation speed

    auto top = std::make_unique<Vddc_top>();

    // Output CSV file for plotting passband frequency response
    std::ofstream csv("sweep_response.csv");
    csv << "frequency_khz,i_amplitude,gain_db\n";

    // Sweep configuration
    const double Fs = 61.44e6;             // 61.44 MHz ADC sample clock
    const double F_start = 1.173e3;        // ~1 kHz (+173 Hz offset so sampling phase walks across peaks at 24/32 kHz)
    const double F_stop  = 47.173e3;       // ~47 kHz (below Nyquist of 96 kSPS)
    const int    STEPS   = 100;            // 100 frequency measurement points
    const int    CYCLES_PER_FREQ = 60000;  // Clock cycles per frequency step (~93 samples @ 96 kSPS)

    top->rst_n = 0;
    top->clk = 0;
    top->uart_rx_pin = 1;                  // UART idle high
    top->ext_freq_tune = 1;                // Override CAT FTW (~0 Hz DC tuning to measure CIC+CFIR passband)
    top->adc_sample = 0;

    // Apply reset
    for (int i = 0; i < 20; ++i) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst_n = 1;

    std::cout << "[SIM] Starting frequency sweep simulation (1 kHz -> 47 kHz)...\n";

    double max_nominal_peak = 0.0;
    std::vector<std::pair<double, double>> results;

    // Step across the frequency range
    for (int s = 0; s < STEPS; ++s) {
        double current_freq = F_start + s * (F_stop - F_start) / STEPS;
        double phase = 0.0;
        double phase_inc = 2.0 * M_PI * current_freq / Fs;

        int64_t peak_val = 0;

        for (int c = 0; c < CYCLES_PER_FREQ; ++c) {
            // Clock low
            top->clk = 0;
            top->eval();

            // Generate 12-bit signed sine wave input (amplitude: 1800 to avoid clipping)
            top->adc_sample = static_cast<int16_t>(1800.0 * std::sin(phase));
            phase += phase_inc;
            if (phase >= 2.0 * M_PI) phase -= 2.0 * M_PI;

            // Clock rising edge
            top->clk = 1;
            top->eval();

            // Sample output after CFIR filter
            if (top->iq_valid) {
                // Measure peak only in the last two-thirds of the window after filter settling
                if (c > (CYCLES_PER_FREQ / 3)) {
                    // Sign-extend 24-bit two's complement value from Verilator to 32-bit int32_t
                    int32_t signed_i = (static_cast<int32_t>(top->i_data) << 8) >> 8;
                    int64_t abs_val = std::abs(static_cast<int64_t>(signed_i));
                    if (abs_val > peak_val) {
                        peak_val = abs_val;
                    }
                }
            }
        }

        if (s == 0) max_nominal_peak = static_cast<double>(peak_val);

        double gain_db = 20.0 * std::log10(static_cast<double>(peak_val) / max_nominal_peak);
        results.push_back({current_freq / 1000.0, gain_db});

        if (s % 10 == 0) {
            std::cout << "  f = " << (current_freq / 1000.0) << " kHz | Peak: "
                      << peak_val << " | Gain: " << gain_db << " dB\n";
        }
    }

    // Write results to CSV
    for (const auto& r : results) {
        csv << r.first << "," << r.second << "\n";
    }
    csv.close();

    std::cout << "[SIM] Done! Results saved to: sweep_response.csv\n";
    return 0;
}
