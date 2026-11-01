module cic_decimator #(
    parameter IN_WIDTH  = 16,
    parameter DECIM_R   = 640,
    parameter OUT_WIDTH = 24
)(
    input  wire                        clk,      // High-speed ADC clock (e.g., 61.44 MHz)
    input  wire                        rst_n,    // Asynchronous or synchronous active-low reset
    input  wire signed [IN_WIDTH-1:0]  in_data,  // Mixer output (I or Q channel)
    output reg  signed [OUT_WIDTH-1:0] out_data, // Decimated baseband sample
    output reg                         out_valid // 1-cycle pulse when new output sample is valid
);

    // Internal register width: 16 + ceil(4 * log2(640)) = 54 bits
    localparam INT_WIDTH = 54;

    // --- 1. INTEGRATOR STAGES (Running at high-speed clock) ---
    reg signed [INT_WIDTH-1:0] itg0 = 0, itg1 = 0, itg2 = 0, itg3 = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            itg0 <= 0; itg1 <= 0; itg2 <= 0; itg3 <= 0;
        end else begin
            itg0 <= itg0 + {{ (INT_WIDTH-IN_WIDTH){in_data[IN_WIDTH-1]} }, in_data};
            itg1 <= itg1 + itg0;
            itg2 <= itg2 + itg1;
            itg3 <= itg3 + itg2;
        end
    end

    // --- 2. SAMPLE RATE DIVIDER (Rate Changer: 1/640) ---
    reg [9:0] count = 0;
    reg sample_en = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count     <= 0;
            sample_en <= 0;
        end else begin
            if (count == DECIM_R - 1) begin
                count     <= 0;
                sample_en <= 1'b1;
            end else begin
                count     <= count + 1;
                sample_en <= 1'b0;
            end
        end
    end

    // --- 3. COMB / DIFFERENTIATOR STAGES (Running at decimated rate) ---
    reg signed [INT_WIDTH-1:0] d_itg3 = 0;
    reg signed [INT_WIDTH-1:0] diff0 = 0, d_diff0 = 0;
    reg signed [INT_WIDTH-1:0] diff1 = 0, d_diff1 = 0;
    reg signed [INT_WIDTH-1:0] diff2 = 0, d_diff2 = 0;
    reg signed [INT_WIDTH-1:0] diff3 = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_itg3    <= 0;
            diff0     <= 0; d_diff0   <= 0;
            diff1     <= 0; d_diff1   <= 0;
            diff2     <= 0; d_diff2   <= 0;
            diff3     <= 0;
            out_valid <= 0;
            out_data  <= 0;
        end else if (sample_en) begin
            // Comb subtractions: y[n] = x[n] - x[n-1]
            diff0   <= itg3 - d_itg3;
            d_itg3  <= itg3;

            diff1   <= diff0 - d_diff0;
            d_diff0 <= diff0;

            diff2   <= diff1 - d_diff1;
            d_diff1 <= diff1;

            diff3   <= diff2 - d_diff2;
            d_diff2 <= diff2;

            // Slice top OUT_WIDTH bits (MSB truncation)
            out_data  <= diff3[INT_WIDTH-1 : INT_WIDTH-OUT_WIDTH];
            out_valid <= 1'b1;
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
