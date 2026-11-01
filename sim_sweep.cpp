#include <iostream>
#include <fstream>
#include <cmath>
#include <memory>
#include <vector>
#include <algorithm>

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vddc_top.h"

// Verilator időfüggvény
vluint64_t main_time = 0;
double sc_time_stamp() {
    return main_time;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(false); // A sebesség miatt most ne írjunk gigabájtos VCD-t

    auto top = std::make_unique<Vddc_top>();

    // Kimeneti CSV fájl a spektrum rajzolásához
    std::ofstream csv("sweep_response.csv");
    csv << "frequency_khz,i_amplitude,gain_db\n";

    // Alapbeállítások
    const double Fs = 61.44e6;             // 61.44 MHz ADC órajel
    const double F_start = 1.0e3;          // 1 kHz
    const double F_stop  = 47.0e3;         // 47 kHz (a 96 kSPS fele)
    const int    STEPS   = 100;            // 100 mérési frekvenciapont
    const int    CYCLES_PER_FREQ = 60000;  // Órajelciklus frekvenciapontonként (~93 minta @ 96 kSPS)

    top->rst_n = 0;
    top->clk = 0;
    top->uart_rx_pin = 1;                  // UART alapállapot (idle high)
    top->ext_freq_tune = 1;                // Külső hangolás engedélyezése (~0 Hz: DC átvitel mérése)
    top->adc_sample = 0;

    // Reset ciklus
    for (int i = 0; i < 20; ++i) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst_n = 1;

    std::cout << "[SIM] Frekvencia-sweep szimuláció indul (1 kHz -> 47 kHz)...\n";

    double max_nominal_peak = 0.0;
    std::vector<std::pair<double, double>> results;

    // Végiglépkedünk a frekvenciatartományon
    for (int s = 0; s < STEPS; ++s) {
        double current_freq = F_start + s * (F_stop - F_start) / STEPS;
        double phase = 0.0;
        double phase_inc = 2.0 * M_PI * current_freq / Fs;

        int64_t peak_val = 0;

        for (int c = 0; c < CYCLES_PER_FREQ; ++c) {
            // Órajel 0
            top->clk = 0;
            top->eval();

            // Bemeneti 12 bites szinusz generálása (amplitúdó: 1800, hogy ne vágjon)
            top->adc_sample = static_cast<int16_t>(1800.0 * std::sin(phase));
            phase += phase_inc;
            if (phase >= 2.0 * M_PI) phase -= 2.0 * M_PI;

            // Órajel 1 (felfutó él)
            top->clk = 1;
            top->eval();

            // Kimeneti mintavételezés a CFIR után
            if (top->iq_valid) {
                // Csak az utolsó harmadban mérünk csúcsot, hogy a szűrő beálljon
                if (c > (CYCLES_PER_FREQ / 3)) {
                    int64_t abs_val = std::abs(static_cast<int32_t>(top->i_data));
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
            std::cout << "  f = " << (current_freq / 1000.0) << " kHz | Csúcsérték: "
                      << peak_val << " | Erősítés: " << gain_db << " dB\n";
        }
    }

    // Eredmények kiírása CSV-be
    for (const auto& r : results) {
        csv << r.first << "," << r.second << "\n";
    }
    csv.close();

    std::cout << "[SIM] Kész! Az eredmény elmentve: sweep_response.csv\n";
    return 0;
}
