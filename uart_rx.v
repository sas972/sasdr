module uart_rx #(
    parameter CLK_FREQ = 61440000,
    parameter BAUD     = 115200
)(
    input  wire       clk,        // Rendszerórajel (pl. 61.44 MHz)
    input  wire       rst_n,      // Aszinkron aktív alacsony reset
    input  wire       uart_rx,    // Fizikai RX láb

    output reg  [7:0] data_out,   // Vett 8-bites adatbájt
    output reg        byte_ready  // 1 órajelciklus széles impulzus, ha új bájt érkezett
);

    // Órajelciklusok száma egyetlen soros bit alatt
    // 61.44 MHz és 115200 baud esetén: 61440000 / 115200 ≈ 533 ciklus
    localparam CLKS_PER_BIT  = CLK_FREQ / BAUD;
    localparam CLKS_HALF_BIT = CLKS_PER_BIT / 2;

    // Állapotgép állapotai
    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_cnt;
    reg [2:0]  bit_idx;
    reg [7:0]  rx_shift;

    // --- 1. Aszinkron bemenet szinkronizálása (Metastability guard) ---
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

    // --- 2. Vételi állapotgép középponti mintavételezéssel ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            clk_cnt    <= 0;
            bit_idx    <= 0;
            rx_shift   <= 8'h00;
            data_out   <= 8'h00;
            byte_ready <= 1'b0;
        end else begin
            byte_ready <= 1'b0; // Alapértelmezetten 0, csak 1 ciklusig aktív

            case (state)
                S_IDLE: begin
                    clk_cnt <= 0;
                    bit_idx <= 0;
                    // Start bit detektálása: a vonal alacsony szintre vált (0)
                    if (rx_sync_2 == 1'b0) begin
                        state <= S_START;
                    end
                end

                S_START: begin
                    // Megvárjuk a start bit KÖZEPÉT (fél bitidő)
                    if (clk_cnt == CLKS_HALF_BIT - 1) begin
                        // Újra ellenőrizzük: ha még mindig 0, akkor valódi start bit (nem zajtüske)
                        if (rx_sync_2 == 1'b0) begin
                            clk_cnt <= 0;
                            state   <= S_DATA;
                        end else begin
                            state   <= S_IDLE; // Hamis start bit, vissza alaphelyzetbe
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                S_DATA: begin
                    // Egy teljes bitidő után mintavételezünk (így mindig a bitek közepére esünk)
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt  <= 0;
                        rx_shift[bit_idx] <= rx_sync_2; // LSB first (először a 0. bit jön)

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
                    // Megvárjuk a stop bit idejét
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        // Szabványos stop bit magas szint (1)
                        if (rx_sync_2 == 1'b1) begin
                            data_out   <= rx_shift;
                            byte_ready <= 1'b1; // Jelezzük a feldolgozónak, hogy kész az adat
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
