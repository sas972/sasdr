module cfir #(
    parameter DATA_WIDTH = 24, // CIC kimeneti felbontás
    parameter COEFF_WIDTH = 16, // Szűrőegyütthatók felbontása
    parameter OUT_WIDTH  = 24  // CFIR kimeneti felbontás
)(
    input  wire                           clk,        // Gyors órajel (61.44 MHz)
    input  wire                           rst_n,      // Aszinkron reset
    input  wire                           in_valid,   // Impulzus a CIC-ből (192 kHz)
    input  wire signed [DATA_WIDTH-1:0]   in_data,    // Nyers CIC minta (I vagy Q)

    output reg  signed [OUT_WIDTH-1:0]    out_data,   // Kompenzált, sima alapsávi minta
    output reg                            out_valid   // Kimeneti kész jel (1 órajel széles)
);

    localparam TAPS = 21;

    // Shift regiszter az előző 21 minta tárolására
    reg signed [DATA_WIDTH-1:0] shift_reg [0:TAPS-1];

    // 21 tagú inverz sinc^4 kompenzáló együttható-tábla (szimmetrikus)
    reg signed [COEFF_WIDTH-1:0] coeff_rom [0:TAPS-1];
    initial begin
        coeff_rom[0]  = -16'sd35;   coeff_rom[1]  =  16'sd28;
        coeff_rom[2]  =  16'sd120;  coeff_rom[3]  = -16'sd180;
        coeff_rom[4]  = -16'sd320;  coeff_rom[5]  =  16'sd620;
        coeff_rom[6]  =  16'sd850;  coeff_rom[7]  = -16'sd1920;
        coeff_rom[8]  = -16'sd2850; coeff_rom[9]  =  16'sd9800;
        coeff_rom[10] =  16'sd22100; // Középső csúcs (h[10])
        coeff_rom[11] =  16'sd9800;  coeff_rom[12] = -16'sd2850;
        coeff_rom[13] = -16'sd1920; coeff_rom[14] =  16'sd850;
        coeff_rom[15] =  16'sd620;  coeff_rom[16] = -16'sd320;
        coeff_rom[17] = -16'sd180;  coeff_rom[18] =  16'sd120;
        coeff_rom[19] =  16'sd28;   coeff_rom[20] = -16'sd35;
    end

    // MAC állapotgép számlálója
    reg [5:0] tap_idx = 0;
    reg       running = 0;

    // Szorzó és Akkumulátor pipeline regiszterek
    reg signed [DATA_WIDTH-1:0]             fetch_data;
    reg signed [COEFF_WIDTH-1:0]            fetch_coeff;
    reg signed [DATA_WIDTH-1:0]             mac_data;
    reg signed [COEFF_WIDTH-1:0]            mac_coeff;
    reg signed [DATA_WIDTH+COEFF_WIDTH-1:0] mult_res;
    reg signed [DATA_WIDTH+COEFF_WIDTH-1:0] mult_pipe;
    reg signed [DATA_WIDTH+COEFF_WIDTH+5:0] acc; // +6 bit tartalék a 21 tag összegzéséhez

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

            // Új minta érkezésekor shiftelés és pipeline nullázása
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
                // Pipeline 1. lépcső: 21:1 MUX kiolvasása dedikált szövet (fabric) regiszterbe
                if (tap_idx < TAPS) begin
                    fetch_data  <= shift_reg[tap_idx];
                    fetch_coeff <= coeff_rom[tap_idx];
                end else begin
                    fetch_data  <= 0;
                    fetch_coeff <= 0;
                end

                // Pipeline 2. lépcső: Gowin MULT18X18 DSP bemeneti regiszterek
                mac_data  <= fetch_data;
                mac_coeff <= fetch_coeff;

                // Pipeline 3. lépcső: szorzás (Gowin DSP kimeneti regiszter)
                mult_res  <= mac_data * mac_coeff;

                // Pipeline 4. lépcső: részeredmény-összeg regisztrálása (elválasztva az akkumulátortól)
                mult_pipe <= mult_res;

                // Pipeline 5. lépcső: 46 bites összegzés (akkumulálás)
                acc       <= acc + mult_pipe;

                tap_idx   <= tap_idx + 1;

                // Szűrés befejezése (21 tap + 4 pipeline lépcső lefutása után)
                if (tap_idx == TAPS + 4) begin
                    running   <= 1'b0;
                    out_valid <= 1'b1;
                    // Skálázás: a szorzás és a koefficiensek normalizálása miatt 
                    // az acc felső bitjeit vágjuk ki a kimenetre
                    out_data  <= acc[DATA_WIDTH+COEFF_WIDTH-2 : COEFF_WIDTH-1];
                end
            end
        end
    end

endmodule
