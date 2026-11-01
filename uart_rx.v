module uart_rx #(
    parameter CLK_FREQ = 61440000,
    parameter BAUD     = 115200
)(
    input  wire       clk,        // System clock (e.g., 61.44 MHz)
    input  wire       rst_n,      // Asynchronous active-low reset
    input  wire       uart_rx,    // Physical UART RX pin

    output reg  [7:0] data_out,   // Received 8-bit data byte
    output reg        byte_ready  // 1-clock-cycle pulse when a new byte is received
);

    // Number of clock cycles per serial bit
    // At 61.44 MHz and 115200 baud: 61440000 / 115200 ≈ 533 cycles
    localparam CLKS_PER_BIT  = CLK_FREQ / BAUD;
    localparam CLKS_HALF_BIT = CLKS_PER_BIT / 2;

    // FSM states
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  rx_shift;

    // --- 1. Synchronize asynchronous input (Metastability guard) ---
    reg rx_sync_1;
    reg rx_sync_2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync_1 <= 1'b1;
            rx_sync_2 <= 1'b1;
        end else begin
            rx_sync_1 <= uart_rx;
            rx_sync_2 <= rx_sync_1;
        end
    end

    // --- 2. Receive FSM with mid-bit sampling ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            clk_cnt    <= 0;
            bit_idx    <= 0;
            rx_shift   <= 8'h00;
            data_out   <= 8'h00;
            byte_ready <= 1'b0;
        end else begin
            byte_ready <= 1'b0; // Default 0, active for 1 clock cycle only

            case (state)
                S_IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    // Detect start bit: line transitions low (0)
                    if (rx_sync_2 == 1'b0) begin
                        state <= S_START;
                    end
                end

                S_START: begin
                    // Wait until the MIDDLE of the start bit (half bit period)
                    if (clk_cnt == CLKS_HALF_BIT - 1) begin
                        // Re-verify: if still 0, valid start bit (not a noise glitch)
                        if (rx_sync_2 == 1'b0) begin
                            clk_cnt <= 0;
                            state   <= S_DATA;
                        end else begin
                            state   <= S_IDLE; // False start bit, return to idle
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                S_DATA: begin
                    // Sample after a full bit period (always hits the center of each data bit)
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt  <= 0;
                        rx_shift[bit_idx] <= rx_sync_2; // LSB first (bit 0 arrives first)

                        if (bit_idx == 7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                S_STOP: begin
                    // Wait one full bit period for the stop bit
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        // Standard stop bit is logic high (1)
                        if (rx_sync_2 == 1'b1) begin
                            data_out   <= rx_shift;
                            byte_ready <= 1'b1; // Signal downstream logic that byte is valid
                        end
                        state <= S_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
