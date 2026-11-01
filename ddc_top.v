module ddc_top #(
    parameter ADC_WIDTH   = 12, // AD9226 felbontása
    parameter NCO_WIDTH   = 12, // NCO fázis/amplitúdó pontosság
    parameter MIX_WIDTH   = 16, // Keverőből a CIC felé menő szélesség
    parameter DECIM_R     = 320,// Decimálási arány (61.44 MHz -> 192 kHz)
    parameter OUT_WIDTH   = 24  // Kimeneti I/Q felbontás
)(
    input  wire                          clk,           // Gyors ADC órajel (pl. 61.44 MHz)
    input  wire                          rst_n,         // Aszinkron reset

    // Fizikai ADC bemenet
    input  wire signed [ADC_WIDTH-1:0]   adc_sample,    // Előjeles bejövő RF minta

    // Fizikai UART lábak (Kenwood CAT vezérlés)
    input  wire                          uart_rx_pin,   // Tang Nano Pin 18
    output wire                          uart_tx_pin,   // Tang Nano Pin 17

    // Fizikai I2S Audio kimeneti lábak
    output wire                          i2s_sck_pin,   // Bit Clock
    output wire                          i2s_ws_pin,    // Word Select (LRCLK)
    output wire                          i2s_sd_pin,    // Serial Data

    // Szimulációs / Debug portok (Verilator testbenchekhez)
    input  wire [31:0]                   ext_freq_tune, // Ha != 0, felülbírálja az UART FTW-t
    output wire signed [OUT_WIDTH-1:0]   i_data,        // Alapsávi In-phase (I) adat
    output wire signed [OUT_WIDTH-1:0]   q_data,        // Alapsávi Quadrature (Q) adat
    output wire                          iq_valid,      // Impulzus 192 kHz-en új minta esetén
    output wire                          tune_led       // Opcionális visszajelző, ha jött CAT parancs
);

    // --- 0. UART ÉS KENWOOD CAT VEZÉRLŐ ---
    wire [7:0]  rx_byte;
    wire        rx_ready;
    wire [7:0]  tx_byte;
    wire        tx_start;
    wire        tx_busy;
    wire [31:0] live_ftw;
    wire        ftw_updated;

    uart_rx #(
        .CLK_FREQ(61440000),
        .BAUD(115200)
    ) u_rx (
        .clk(clk),
        .rst_n(rst_n),
        .uart_rx(uart_rx_pin),
        .data_out(rx_byte),
        .byte_ready(rx_ready)
    );

    ddc_cat_kenwood u_cat (
        .clk(clk),
        .rst_n(rst_n),
        .byte_ready(rx_ready),
        .rx_byte(rx_byte),
        .tx_byte(tx_byte),
        .tx_start(tx_start),
        .tx_busy(tx_busy),
        .freq_tune(live_ftw),
        .tune_valid(ftw_updated)
    );

    uart_tx #(
        .CLK_FREQ(61440000),
        .BAUD(115200)
    ) u_tx (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_byte),
        .tx_start(tx_start),
        .tx_busy(tx_busy),
        .uart_tx(uart_tx_pin)
    );

    // Ha szimulációban kívülről adunk ext_freq_tune-t, azt használja, 
    // különben a Kenwood CAT-ból érkező live_ftw-t!
    wire [31:0] active_ftw = (ext_freq_tune != 32'd0) ? ext_freq_tune : live_ftw;
    assign tune_led = ftw_updated;

    // --- 1. NCO PÉLDÁNYOSÍTÁSA ---
    wire signed [NCO_WIDTH-1:0] nco_cos;
    wire signed [NCO_WIDTH-1:0] nco_neg_sin;

    nco #(
        .PHASE_WIDTH(32),
        .OUT_WIDTH(NCO_WIDTH)
    ) u_nco (
        .clk(clk),
        .rst_n(rst_n),
        .phase_inc(active_ftw), // <-- Itt van bekötve a live_ftw!
        .cos_out(nco_cos),
        .neg_sin_out(nco_neg_sin)
    );

    // --- 2. KOMPLEX KEVERŐ (MIXER) ---
    reg signed [23:0] prod_i;
    reg signed [23:0] prod_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_i <= 24'sd0;
            prod_q <= 24'sd0;
        end else begin
            prod_i <= adc_sample * nco_cos;     // Javítva a * szorzójel
            prod_q <= adc_sample * nco_neg_sin; // Javítva a * szorzójel
        end
    end

    wire signed [MIX_WIDTH-1:0] mix_i = prod_i[22 : 23-MIX_WIDTH];
    wire signed [MIX_WIDTH-1:0] mix_q = prod_q[22 : 23-MIX_WIDTH];

    // --- 3. CIC DECIMÁTOROK (I ÉS Q ÁG) ---
    wire signed [OUT_WIDTH-1:0] cic_i_data, cic_q_data;
    wire cic_valid;

    cic_decimator #(
        .IN_WIDTH(MIX_WIDTH),
        .DECIM_R(DECIM_R),
        .OUT_WIDTH(OUT_WIDTH)
    ) u_cic_i (
        .clk(clk),
        .rst_n(rst_n),
        .in_data(mix_i),
        .out_data(cic_i_data),
        .out_valid(cic_valid)
    );

    cic_decimator #(
        .IN_WIDTH(MIX_WIDTH),
        .DECIM_R(DECIM_R),
        .OUT_WIDTH(OUT_WIDTH)
    ) u_cic_q (
        .clk(clk),
        .rst_n(rst_n),
        .in_data(mix_q),
        .out_data(cic_q_data),
        .out_valid()
    );

    // --- 4. CFIR DROOP-KOMPENZÁLÓ SZŰRŐK ---
    cfir #(OUT_WIDTH, 16, OUT_WIDTH) u_cfir_i (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(cic_valid),
        .in_data(cic_i_data),
        .out_data(i_data),
        .out_valid(iq_valid)
    );

    cfir #(OUT_WIDTH, 16, OUT_WIDTH) u_cfir_q (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(cic_valid),
        .in_data(cic_q_data),
        .out_data(q_data),
        .out_valid()
    );

    // --- 5. I2S AUDIO TRANSZMITTER ---
    i2s_tx #(
        .DATA_WIDTH(24),
        .CLK_DIV(10) // 61.44 MHz -> 48 kHz sztereó I2S
    ) u_i2s_tx (
        .clk(clk),
        .rst_n(rst_n),
        .iq_valid(iq_valid),
        .i_data(i_data),
        .q_data(q_data),
        .i2s_sck(i2s_sck_pin),
        .i2s_ws(i2s_ws_pin),
        .i2s_sd(i2s_sd_pin)
    );

endmodule

