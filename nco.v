module nco #(
    parameter PHASE_WIDTH = 32,
    parameter OUT_WIDTH   = 12
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [PHASE_WIDTH-1:0]       phase_inc, // Frequency Tuning Word (FTW)
    output reg  signed [OUT_WIDTH-1:0]  cos_out,
    output reg  signed [OUT_WIDTH-1:0]  neg_sin_out
);

    reg [PHASE_WIDTH-1:0]        phase_acc;
    reg signed [OUT_WIDTH-1:0]   sin_lut_val;
    reg signed [OUT_WIDTH-1:0]   cos_lut_val;

    // 1024-entry, 12-bit sine/cosine lookup tables (initialized via $readmemh)
    reg signed [OUT_WIDTH-1:0] lut_sin [0:1023];
    reg signed [OUT_WIDTH-1:0] lut_cos [0:1023];

    initial begin
        $readmemh("sin_lut.hex", lut_sin);
        $readmemh("cos_lut.hex", lut_cos);
    end

    // Phase accumulator + 2-stage LUT readout and negation (for BSRAM inference and high f_max)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc   <= 0;
            sin_lut_val <= 0;
            cos_lut_val <= 0;
            cos_out     <= 0;
            neg_sin_out <= 0;
        end else begin
            phase_acc   <= phase_acc + phase_inc;
            // Stage 1: Synchronous LUT readout addressed by the top 10 phase bits
            cos_lut_val <= lut_cos[phase_acc[PHASE_WIDTH-1 : PHASE_WIDTH-10]];
            sin_lut_val <= lut_sin[phase_acc[PHASE_WIDTH-1 : PHASE_WIDTH-10]];
            // Stage 2: Register negation separately to break the critical timing path
            cos_out     <= cos_lut_val;
            neg_sin_out <= -sin_lut_val;
        end
    end

endmodule
