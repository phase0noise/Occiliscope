module uart_tx #(
    parameter integer CLOCK_FREQ = 50000000,
    parameter integer BAUD_RATE = 9600,
    parameter integer HIGH_BAUD_RATE = 115200
)(
    input clk,
    input reset,
    input high_speed,
    input tx_start,
    input [7:0] tx_data,
    output reg tx,
    output reg tx_ready
);

    localparam integer CLKS_PER_BIT_LOW  = CLOCK_FREQ / BAUD_RATE;
    localparam integer CLKS_PER_BIT_HIGH = CLOCK_FREQ / HIGH_BAUD_RATE;
    wire [15:0] clks_per_bit = high_speed ? CLKS_PER_BIT_HIGH : CLKS_PER_BIT_LOW;
    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA = 2'd2;
    localparam [1:0] STOP = 2'd3;

    reg [1:0] state;
    reg [15:0] clk_count;
    reg [2:0] bit_index;
    reg [7:0] tx_shift;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            clk_count <= 16'd0;
            bit_index <= 3'd0;
            tx <= 1'b1;
            tx_ready <= 1'b1;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1'b1;
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;
                    tx_ready <= 1'b1;
                    if (tx_start) begin
                        tx_shift <= tx_data;
                        state <= START;
                        tx_ready <= 1'b0;
                    end
                end
                START: begin
                    tx <= 1'b0;
                    if (clk_count == clks_per_bit - 1'b1) begin
                        clk_count <= 16'd0;
                        state <= DATA;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end
                DATA: begin
                    tx <= tx_shift[bit_index];
                    if (clk_count == clks_per_bit - 1'b1) begin
                        clk_count <= 16'd0;
                        if (bit_index == 3'd7)
                            state <= STOP;
                        else
                            bit_index <= bit_index + 3'd1;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end
                STOP: begin
                    tx <= 1'b1;
                    if (clk_count == clks_per_bit - 1'b1) begin
                        clk_count <= 16'd0;
                        state <= IDLE;
                        tx_ready <= 1'b1;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end
            endcase
        end
    end
endmodule
