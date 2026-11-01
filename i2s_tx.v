module i2s_tx #(
    parameter DATA_WIDTH  = 24,
    // CLK_DIV = (f_clk / (f_sample * 64 * 2))
    // 61.44 MHz órajelnél 48 kHz mintavételhez: 61440000 / (48000 * 64 * 2) = 10
    // 61.44 MHz órajelnél 192 kHz mintavételhez: CLK_DIV = 2.5 -> érdemes fix osztót használni
    parameter CLK_DIV     = 10  
)(
    input  wire                         clk,        // Rendszerórajel (61.44 MHz)
    input  wire                         rst_n,      // Aszinkron reset

    // Bemeneti I/Q minták a CFIR szűrőkből
    input  wire                         iq_valid,   // Impulzus, ha új CFIR minta érkezett
    input  wire signed [DATA_WIDTH-1:0] i_data,     // Bal csatorna (I)
    input  wire signed [DATA_WIDTH-1:0] q_data,     // Jobb csatorna (Q)

    // Fizikai I2S kimeneti lábak
    output reg                          i2s_sck,    // Bit Clock
    output reg                          i2s_ws,     // Word Select (LRCLK: 0=Left/I, 1=Right/Q)
    output reg                          i2s_sd      // Serial Data
);

    // Bemeneti minták pufferelése, hogy a lassan kiolvasott adat stabil maradjon
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

    // Órajelosztó az i2s_sck előállításához
    reg [7:0] clk_cnt;
    wire      sck_pulse = (clk_cnt == CLK_DIV - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt <= 0;
            i2s_sck <= 0;
        end else begin
            if (sck_pulse) begin
                clk_cnt <= 0;
                i2s_sck <= ~i2s_sck; // SCK élváltás
            end else begin
                clk_cnt <= clk_cnt + 1;
            end
        end
    end

    // SCK lefutó és felfutó él detektálása a fő órajelen
    wire sck_falling = (sck_pulse && (i2s_sck == 1'b1));
    // wire sck_rising  = (sck_pulse && (i2s_sck == 1'b0));

    // 64 bites állapotgép számlálója (0..31: Bal/I, 32..63: Jobb/Q)
    reg [5:0] bit_cnt;
    reg [31:0] shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt   <= 0;
            i2s_ws    <= 0;
            i2s_sd    <= 0;
            shift_reg <= 0;
        end else if (sck_falling) begin
            // Az adatot az SCK lefutó élére állítjuk be, hogy a vevő 
            // a felfutó élre stabilan mintavételezhesse (setup/hold idő).

            // 1. Word Select (ws) állapotváltás a keret szélén
            if (bit_cnt == 63) begin
                i2s_ws  <= 1'b0; // Váltás Bal (I) csatornára
                bit_cnt <= 0;
                // Bal csatorna adatai betöltve a shift regiszterbe:
                // [24 bites adat] + [8 bit kitöltő 0]
                shift_reg <= {i_latched, 8'h00};
            end else if (bit_cnt == 31) begin
                i2s_ws  <= 1'b1; // Váltás Jobb (Q) csatornára
                bit_cnt <= bit_cnt + 1;
                // Jobb csatorna adatai betöltve
                shift_reg <= {q_latched, 8'h00};
            end else begin
                bit_cnt   <= bit_cnt + 1;
                shift_reg <= {shift_reg[30:0], 1'b0}; // Shiftelés balra (MSB first)
            end

            // 2. Az 1-ciklusos I2S késleltetés logikája
            // bit_cnt = 0 és 32 esetén (közvetlenül a ws váltás után) 
            // az I2S szabvány szerint az adat még nem kezdődik el!
            if (bit_cnt == 0 || bit_cnt == 32) begin
                i2s_sd <= 1'b0;
            end else begin
                i2s_sd <= shift_reg[31];
            end
        end
    end

endmodule
