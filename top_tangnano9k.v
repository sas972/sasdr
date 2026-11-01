module top_tangnano9k (
    input  wire        clk,          // Pin 52 (27 MHz or external 61.44 MHz ADC clock)
    input  wire        rst_n,        // Pin 3 (Tang Nano S1 button, active-low)
    input  wire [11:0] adc_data,     // AD9226 12-bit parallel input

    input  wire        uart_rx_pin,  // Pin 18 (USB-UART RX)
    output wire        uart_tx_pin,  // Pin 17 (USB-UART TX)

    output wire        i2s_sck_pin,  // I2S Bit Clock
    output wire        i2s_ws_pin,   // I2S Word Select (LRCLK)
    output wire        i2s_sd_pin,   // I2S Serial Data

    output wire [5:0]  led           // Tang Nano 6 onboard LEDs
);

    // AD9226 Offset Binary -> Two's Complement conversion (invert MSB)
    wire signed [11:0] signed_adc = {~adc_data[11], adc_data[10:0]};

    wire signed [23:0] i_out, q_out;
    wire               iq_valid;
    wire               tune_pulse;

    // Instantiate full DDC + CFIR + CAT + I2S pipeline
    ddc_top u_ddc (
        .clk(clk),
        .rst_n(rst_n),
        .adc_sample(signed_adc),
        .uart_rx_pin(uart_rx_pin),
        .uart_tx_pin(uart_tx_pin),
        .i2s_sck_pin(i2s_sck_pin),
        .i2s_ws_pin(i2s_ws_pin),
        .i2s_sd_pin(i2s_sd_pin),
        .ext_freq_tune(32'd0), // Controlled via UART CAT on physical hardware
        .i_data(i_out),
        .q_data(q_out),
        .iq_valid(iq_valid),
        .tune_led(tune_pulse)
    );

    // Visual feedback: output the top 6 bits of the I channel to onboard LEDs (level meter)
    assign led = ~i_out[23:18];

endmodule
