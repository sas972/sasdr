module top_tangnano9k (
    input  wire        clk,          // Pin 52 (27 MHz vagy külső ADC órajel)
    input  wire        rst_n,        // Pin 3 (Tang Nano S1 gomb, aktív alacsony)
    input  wire [11:0] adc_data,     // AD9226 12 bites bemenet

    input  wire        uart_rx_pin,  // Pin 18 (USB-UART RX)
    output wire        uart_tx_pin,  // Pin 17 (USB-UART TX)

    output wire        i2s_sck_pin,  // I2S Bit Clock
    output wire        i2s_ws_pin,   // I2S Word Select (LRCLK)
    output wire        i2s_sd_pin,   // I2S Data

    output wire [5:0]  led           // Tang Nano 6 db fedélzeti LED
);

    // AD9226 Offset Binary -> Kettes komplemens (MSB invertálás)
    wire signed [11:0] signed_adc = {~adc_data[11], adc_data[10:0]};

    wire signed [23:0] i_out, q_out;
    wire               iq_valid;
    wire               tune_pulse;

    // A teljes DDC + CFIR + CAT + I2S példányosítása
    ddc_top u_ddc (
        .clk(clk),
        .rst_n(rst_n),
        .adc_sample(signed_adc),
        .uart_rx_pin(uart_rx_pin),
        .uart_tx_pin(uart_tx_pin),
        .i2s_sck_pin(i2s_sck_pin),
        .i2s_ws_pin(i2s_ws_pin),
        .i2s_sd_pin(i2s_sd_pin),
        .ext_freq_tune(32'd0), // Fizikai kártyán az UART CAT vezérel!
        .i_data(i_out),
        .q_data(q_out),
        .iq_valid(iq_valid),
        .tune_led(tune_pulse)
    );

    // Vizuális visszajelzés: az I ág legfelső 6 bitjét kirakjuk a LED-ekre (kivezérlésjelző!)
    assign led = ~i_out[23:18];

endmodule
