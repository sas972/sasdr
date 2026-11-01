module nco #(
    parameter PHASE_WIDTH = 32,
    parameter OUT_WIDTH   = 12
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [PHASE_WIDTH-1:0]       phase_inc, // Hangolási frekvencia (FTW)
    output reg  signed [OUT_WIDTH-1:0]  cos_out,
    output reg  signed [OUT_WIDTH-1:0]  neg_sin_out
);

    reg [PHASE_WIDTH-1:0] phase_acc;

    // 1024 elemű, 12 bites szinusz lookup table (1/4 hullám vagy teljes hullám)
    // Inicializálható $readmemh-val vagy képlettel
    reg signed [OUT_WIDTH-1:0] lut_sin [0:1023];
    reg signed [OUT_WIDTH-1:0] lut_cos [0:1023];

    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) begin
            // 2 * PI * i / 1024 számítása 12 bites skálán (max 2047)
            lut_sin[i] = $rtoi(2047.0 * $sin(2.0 * 3.1415926535 * i / 1024.0));
            lut_cos[i] = $rtoi(2047.0 * $cos(2.0 * 3.1415926535 * i / 1024.0));
        end
    end

    // Fázisakkumulátor
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_acc <= 0;
            cos_out   <= 0;
            neg_sin_out <= 0;
        end else begin
            phase_acc <= phase_acc + phase_inc;
            // A felső 10 bit címzi a LUT-ot
            cos_out     <= lut_cos[phase_acc[PHASE_WIDTH-1 : PHASE_WIDTH-10]];
            neg_sin_out <= -lut_sin[phase_acc[PHASE_WIDTH-1 : PHASE_WIDTH-10]];
        end
    end

endmodule
