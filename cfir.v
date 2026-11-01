module cfir #(
    parameter DATA_WIDTH  = 24, // CIC output resolution
    parameter COEFF_WIDTH = 16, // Filter coefficient resolution
    parameter OUT_WIDTH   = 24  // CFIR output resolution
)(
    input  wire                           clk,        // High-speed clock (61.44 MHz)
    input  wire                           rst_n,      // Asynchronous active-low reset
    input  wire                           in_valid,   // Pulse from CIC (96 kHz)
    input  wire signed [DATA_WIDTH-1:0]   in_data,    // Raw CIC sample (I or Q)

    output reg  signed [OUT_WIDTH-1:0]    out_data,   // Droop-compensated baseband sample
    output reg                            out_valid   // Output valid pulse (1 clock cycle wide)
);

    localparam TAPS = 21;

    // Shift register storing the last 21 samples
    reg signed [DATA_WIDTH-1:0] shift_reg [0:TAPS-1];

    // 21-tap symmetric inverse sinc^4 compensating coefficient table (DC sum = 16384 = 2^14)
    reg signed [COEFF_WIDTH-1:0] coeff_rom [0:TAPS-1];
    initial begin
        coeff_rom[0]  =  16'sd188;   coeff_rom[1]  = -16'sd244;
        coeff_rom[2]  =  16'sd156;   coeff_rom[3]  =  16'sd207;
        coeff_rom[4]  = -16'sd946;   coeff_rom[5]  =  16'sd2043;
        coeff_rom[6]  = -16'sd3274;  coeff_rom[7]  =  16'sd4086;
        coeff_rom[8]  = -16'sd3295;  coeff_rom[9]  = -16'sd2154;
        coeff_rom[10] =  16'sd22850; // Center peak tap (h[10])
        coeff_rom[11] = -16'sd2154;  coeff_rom[12] = -16'sd3295;
        coeff_rom[13] =  16'sd4086;  coeff_rom[14] = -16'sd3274;
        coeff_rom[15] =  16'sd2043;  coeff_rom[16] = -16'sd946;
        coeff_rom[17] =  16'sd207;   coeff_rom[18] =  16'sd156;
        coeff_rom[19] = -16'sd244;   coeff_rom[20] =  16'sd188;
    end

    // MAC state machine counter
    reg [5:0] tap_idx = 0;
    reg       running = 0;

    // Multiplier and accumulator pipeline registers
    reg signed [DATA_WIDTH-1:0]             fetch_data;
    reg signed [COEFF_WIDTH-1:0]            fetch_coeff;
    reg signed [DATA_WIDTH-1:0]             mac_data;
    reg signed [COEFF_WIDTH-1:0]            mac_coeff;
    reg signed [DATA_WIDTH+COEFF_WIDTH-1:0] mult_res;
    reg signed [DATA_WIDTH+COEFF_WIDTH-1:0] mult_pipe;
    reg signed [DATA_WIDTH+COEFF_WIDTH+5:0] acc; // +6 bits of headroom for summing 21 taps

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tap_idx     <= 0;
            running     <= 0;
            fetch_data  <= 0;
            fetch_coeff <= 0;
            mac_data    <= 0;
            mac_coeff   <= 0;
            mult_res    <= 0;
            mult_pipe   <= 0;
            acc         <= 0;
            out_valid   <= 0;
            out_data    <= 0;
            for (i = 0; i < TAPS; i = i + 1) shift_reg[i] <= 0;
        end else begin
            out_valid <= 1'b0;

            // On new sample arrival: shift delay line and clear MAC pipeline
            if (in_valid) begin
                for (i = TAPS-1; i > 0; i = i - 1) begin
                    shift_reg[i] <= shift_reg[i-1];
                end
                shift_reg[0] <= in_data;

                tap_idx     <= 0;
                running     <= 1'b1;
                fetch_data  <= 0;
                fetch_coeff <= 0;
                mac_data    <= 0;
                mac_coeff   <= 0;
                mult_res    <= 0;
                mult_pipe   <= 0;
                acc         <= 0;
            end else if (running) begin
                // Pipeline Stage 1: Read 21:1 MUX into dedicated fabric registers
                if (tap_idx < TAPS) begin
                    fetch_data  <= shift_reg[tap_idx];
                    fetch_coeff <= coeff_rom[tap_idx];
                end else begin
                    fetch_data  <= 0;
                    fetch_coeff <= 0;
                end

                // Pipeline Stage 2: Gowin MULT18X18 DSP input registers
                mac_data  <= fetch_data;
                mac_coeff <= fetch_coeff;

                // Pipeline Stage 3: Multiplication (Gowin DSP output register)
                mult_res  <= mac_data * mac_coeff;

                // Pipeline Stage 4: Register partial-product sum (decoupled from accumulator)
                mult_pipe <= mult_res;

                // Pipeline Stage 5: 46-bit accumulation
                acc       <= acc + mult_pipe;

                tap_idx   <= tap_idx + 1;

                // Complete filtering after 21 taps + 4 pipeline stages have flushed
                if (tap_idx == TAPS + 4) begin
                    running   <= 1'b0;
                    out_valid <= 1'b1;
                    // Scaling: divide by 2^14 (16384) to normalize unity DC gain
                    out_data  <= acc[DATA_WIDTH+COEFF_WIDTH-3 : COEFF_WIDTH-2];
                end
            end
        end
    end

endmodule
