module ddc_top #(
    parameter ADC_WIDTH   = 12, // AD9226 felbontása
    parameter NCO_WIDTH   = 12, // NCO fázis/amplitúdó pontosság
    parameter MIX_WIDTH   = 16, // Keverőből a CIC felé menő szélesség
    parameter DECIM_R     = 320,// Decimálási arány (61.44 MHz -> 192 kHz)
    parameter OUT_WIDTH   = 24  // Kimeneti I/Q felbontás
)(
    input  wire                          clk,        // Gyors ADC órajel (pl. 61.44 MHz)
    input  wire                          rst_n,      // Aszinkron reset
    input  wire [31:0]                   freq_tune,  // NCO frekvenciavezérlő szó (FTW)
    input  wire signed [ADC_WIDTH-1:0]   adc_sample, // Előjeles bejövő RF minta

    output wire signed [OUT_WIDTH-1:0]   i_data,     // Alapsávi In-phase (I) adat
    output wire signed [OUT_WIDTH-1:0]   q_data,     // Alapsávi Quadrature (Q) adat
    output wire                          iq_valid    // Impulzus 192 kHz-en új minta esetén
);

    // --- 1. NCO PÉLDÁNYOSÍTÁSA ---
    wire signed [NCO_WIDTH-1:0] nco_cos;
    wire signed [NCO_WIDTH-1:0] nco_neg_sin;

    nco #(
        .PHASE_WIDTH(32),
        .OUT_WIDTH(NCO_WIDTH)
    ) u_nco (
        .clk(clk),
        .rst_n(rst_n),
        .phase_inc(freq_tune),
        .cos_out(nco_cos),
        .neg_sin_out(nco_neg_sin)
    );

    // --- 2. KOMPLEX KEVERŐ (MIXER) ---
    // A 12 bit x 12 bit szorzás 24 bites eredményt ad.
    // Egy órajelciklus pipeline regisztert használunk a szorzónak, 
    // hogy a Gowin DSP blokk könnyen elérje a 100+ MHz sebességet.
    reg signed [23:0] prod_i;
    reg signed [23:0] prod_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_i <= 24'sd0;
            prod_q <= 24'sd0;
        end else begin
            prod_i <= adc_sample * nco_cos;
            prod_q <= adc_sample * nco_neg_sin;
        end
    end

    // A szorzat legfelső 16 bitjét vezetjük be a CIC szűrőkbe
    wire signed [MIX_WIDTH-1:0] mix_i = prod_i[22 : 23-MIX_WIDTH];
    wire signed [MIX_WIDTH-1:0] mix_q = prod_q[22 : 23-MIX_WIDTH];


    wire signed [OUT_WIDTH-1:0] cic_i_data, cic_q_data;
    wire cic_valid;

    // --- 3. CIC DECIMÁTOR: I (IN-PHASE) ÁG ---
    cic_decimator #(
        .IN_WIDTH(MIX_WIDTH),
        .DECIM_R(DECIM_R),
        .OUT_WIDTH(OUT_WIDTH)
    ) u_cic_i (
        .clk(clk),
        .rst_n(rst_n),
        .in_data(mix_i),
        .out_data(cic_i_data),
        .out_valid(cic_valid) // Mindkét szűrő szinkronban lép, elég egy valid jel
    );

    // --- 4. CIC DECIMÁTOR: Q (QUADRATURE) ÁG ---
    cic_decimator #(
        .IN_WIDTH(MIX_WIDTH),
        .DECIM_R(DECIM_R),
        .OUT_WIDTH(OUT_WIDTH)
    ) u_cic_q (
        .clk(clk),
        .rst_n(rst_n),
        .in_data(mix_q),
        .out_data(cic_q_data),
        .out_valid()         // Ezt a kimenetet nem kell bekötni
    );

    // --- 5. CFIR DROOP-KOMPENZÁLÓ SZŰRŐK ---
    cfir #(OUT_WIDTH, 16, OUT_WIDTH) u_cfir_i (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(cic_valid),
        .in_data(cic_i_data),
        .out_data(i_data),
        .out_valid(iq_valid) // A végső valid jel
    );

    cfir #(OUT_WIDTH, 16, OUT_WIDTH) u_cfir_q (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(cic_valid),
        .in_data(cic_q_data),
        .out_data(q_data),
        .out_valid()
    );

endmodule
