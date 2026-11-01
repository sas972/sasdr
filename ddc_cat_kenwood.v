module ddc_cat_kenwood (
    input  wire        clk,
    input  wire        rst_n,

    // Signals from UART RX
    input  wire        byte_ready,
    input  wire [7:0]  rx_byte,

    // Control signals to UART TX
    output reg  [7:0]  tx_byte,
    output reg         tx_start,
    input  wire        tx_busy,

    // Frequency tuning word output to DDC NCO
    output reg  [31:0] freq_tune,
    output reg         tune_valid
);

    // K = round((2^32 / 61.44e6) * 2^16) = 4581278
    localparam [63:0] SCALE_FACTOR = 64'd4581278;

    localparam [1:0] RX_IDLE = 2'd0;
    localparam [1:0] RX_F    = 2'd1;
    localparam [1:0] RX_FA   = 2'd2;
    localparam [1:0] RX_CALC = 2'd3;

    reg [1:0]  rx_state;
    reg [3:0]  digit_count;
    reg [31:0] acc_freq;
    reg        trigger_tx;

    // Direct ASCII storage for the 11 frequency digits (avoids hardware division by 10 on readback)
    reg [7:0] rx_digits   [0:10]; // Temporary incoming ASCII digits
    reg [7:0] curr_digits [0:10]; // Currently active frequency ASCII digits

    wire [63:0] mult_res = {32'd0, acc_freq} * SCALE_FACTOR;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state    <= RX_IDLE;
            digit_count <= 4'd0;
            acc_freq    <= 32'd0;
            freq_tune   <= 32'd494515985; // 7.074 MHz default tuning word
            tune_valid  <= 1'b0;
            trigger_tx  <= 1'b0;

            // Default ASCII frequency: "00007074000" (7.074 MHz)
            curr_digits[0] <= "0"; curr_digits[1] <= "0"; curr_digits[2] <= "0";
            curr_digits[3] <= "0"; curr_digits[4] <= "7"; curr_digits[5] <= "0";
            curr_digits[6] <= "7"; curr_digits[7] <= "4"; curr_digits[8] <= "0";
            curr_digits[9] <= "0"; curr_digits[10] <= "0";
            for (i = 0; i < 11; i = i + 1) rx_digits[i] <= "0";
        end else begin
            tune_valid <= 1'b0;
            trigger_tx <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    if (byte_ready && (rx_byte == "F" || rx_byte == "f")) begin
                        rx_state <= RX_F;
                    end
                end

                RX_F: begin
                    if (byte_ready) begin
                        if (rx_byte == "A" || rx_byte == "a") begin
                            digit_count <= 4'd0;
                            acc_freq    <= 32'd0;
                            rx_state    <= RX_FA;
                        end else begin
                            rx_state <= RX_IDLE;
                        end
                    end
                end

                RX_FA: begin
                    if (byte_ready) begin
                        if (rx_byte == ";") begin
                            trigger_tx <= 1'b1; // Query command ("FA;")
                            rx_state   <= RX_IDLE;
                        end else if (rx_byte >= "0" && rx_byte <= "9") begin
                            acc_freq <= (acc_freq * 32'd10) + {24'd0, (rx_byte - 8'd48)};
                            rx_digits[digit_count] <= rx_byte;
                            digit_count <= digit_count + 4'd1;
                            if (digit_count == 4'd10) begin
                                rx_state <= RX_CALC;
                            end
                        end else begin
                            rx_state <= RX_IDLE;
                        end
                    end
                end

                RX_CALC: begin
                    if (byte_ready && rx_byte == ";") begin
                        freq_tune  <= mult_res[47:16];
                        tune_valid <= 1'b1;
                        trigger_tx <= 1'b1;
                        for (i = 0; i < 11; i = i + 1) begin
                            curr_digits[i] <= rx_digits[i];
                        end
                        rx_state <= RX_IDLE;
                    end else if (byte_ready) begin
                        rx_state <= RX_IDLE;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // --- TRANSMIT STATE MACHINE ("FA" + 11 digits + ";") ---
    reg [3:0] tx_idx;
    reg       tx_running;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_start   <= 1'b0;
            tx_byte    <= 8'h00;
            tx_idx     <= 4'd0;
            tx_running <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            if (trigger_tx && !tx_running) begin
                tx_idx     <= 4'd0;
                tx_running <= 1'b1;
            end else if (tx_running) begin
                if (!tx_busy && !tx_start) begin
                    if (tx_idx == 4'd0) begin
                        tx_byte  <= "F";
                        tx_start <= 1'b1;
                        tx_idx   <= tx_idx + 4'd1;
                    end else if (tx_idx == 4'd1) begin
                        tx_byte  <= "A";
                        tx_start <= 1'b1;
                        tx_idx   <= tx_idx + 4'd1;
                    end else if (tx_idx >= 4'd2 && tx_idx <= 4'd12) begin
                        tx_byte  <= curr_digits[tx_idx - 4'd2];
                        tx_start <= 1'b1;
                        tx_idx   <= tx_idx + 4'd1;
                    end else if (tx_idx == 4'd13) begin
                        tx_byte    <= ";";
                        tx_start   <= 1'b1;
                        tx_running <= 1'b0; // Final character queued
                    end
                end
            end
        end
    end

endmodule
