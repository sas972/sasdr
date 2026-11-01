module i2s_tx #(
    parameter DATA_WIDTH  = 24,
    // CLK_DIV = (f_clk / (f_sample * 64 * 2))
    // At 61.44 MHz clock for 96 kHz sample rate: 61440000 / (96000 * 64 * 2) = 5
    // At 61.44 MHz clock for 48 kHz sample rate: 61440000 / (48000 * 64 * 2) = 10
    parameter CLK_DIV     = 5   
)(
    input  wire                         clk,        // System clock (61.44 MHz)
    input  wire                         rst_n,      // Asynchronous active-low reset

    // Input I/Q samples from CFIR filters
    input  wire                         iq_valid,   // Pulse when a new CFIR sample arrives
    input  wire signed [DATA_WIDTH-1:0] i_data,     // Left channel (I)
    input  wire signed [DATA_WIDTH-1:0] q_data,     // Right channel (Q)

    // Physical I2S output pins
    output reg                          i2s_sck,    // Serial Bit Clock (BCLK)
    output reg                          i2s_ws,     // Word Select (LRCLK: 0=Left/I, 1=Right/Q)
    output reg                          i2s_sd      // Serial Data (SD)
);

    // Latch incoming samples so they remain stable during serial readout
    reg signed [DATA_WIDTH-1:0] i_latched;
    reg signed [DATA_WIDTH-1:0] q_latched;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_latched <= 0;
            q_latched <= 0;
        end else if (iq_valid) begin
            i_latched <= i_data;
            q_latched <= q_data;
        end
    end

    // Clock divider for generating i2s_sck
    reg [7:0] clk_cnt;
    wire      sck_pulse = (clk_cnt == CLK_DIV - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt <= 0;
            i2s_sck <= 0;
        end else begin
            if (sck_pulse) begin
                clk_cnt <= 0;
                i2s_sck <= ~i2s_sck; // Toggle SCK edge
            end else begin
                clk_cnt <= clk_cnt + 1;
            end
        end
    end

    // Detect SCK falling edge on the master clock
    wire sck_falling = (sck_pulse && (i2s_sck == 1'b1));

    // 64-bit frame counter (0..31: Left/I, 32..63: Right/Q)
    reg [5:0]  bit_cnt;
    reg [31:0] shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt   <= 0;
            i2s_ws    <= 0;
            i2s_sd    <= 0;
            shift_reg <= 0;
        end else if (sck_falling) begin
            // Update serial data on SCK falling edge so the receiver can
            // reliably sample on the rising edge (setup/hold margin).

            // 1. Word Select (WS) transition at frame boundaries
            if (bit_cnt == 63) begin
                i2s_ws  <= 1'b0; // Switch to Left (I) channel
                bit_cnt <= 0;
                // Load Left channel into shift register: [24-bit data] + [8-bit zero padding]
                shift_reg <= {i_latched, 8'h00};
            end else if (bit_cnt == 31) begin
                i2s_ws  <= 1'b1; // Switch to Right (Q) channel
                bit_cnt <= bit_cnt + 1;
                // Load Right channel into shift register
                shift_reg <= {q_latched, 8'h00};
            end else begin
                bit_cnt   <= bit_cnt + 1;
                shift_reg <= {shift_reg[30:0], 1'b0}; // Shift left (MSB first)
            end

            // 2. Standard 1-cycle I2S MSB delay after WS transition
            // At bit_cnt = 0 and 32 (immediately after WS edge), data output is 0
            if (bit_cnt == 0 || bit_cnt == 32) begin
                i2s_sd <= 1'b0;
            end else begin
                i2s_sd <= shift_reg[31];
            end
        end
    end

endmodule
