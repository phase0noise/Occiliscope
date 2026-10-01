module uart_rx #(
    parameter integer CLOCK_FREQ = 50000000,
    parameter integer BAUD_RATE  = 9600,
    parameter integer HIGH_BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       high_speed,
    input  wire       rx,
    output reg [7:0]  rx_data,
    output reg        rx_valid,
    output reg        rx_frame_error
);
    // Sixteen samples per UART bit provide tolerance for baud-rate mismatch
    // and jitter. Three samples around each bit center determine its value.
    localparam integer OVERSAMPLE        = 16;
    localparam integer CLOCKS_PER_SAMPLE_LOW = CLOCK_FREQ / (BAUD_RATE * OVERSAMPLE);
    localparam integer CLOCKS_PER_SAMPLE_HIGH = CLOCK_FREQ / (HIGH_BAUD_RATE * OVERSAMPLE);
    wire [15:0] clocks_per_sample = high_speed ? CLOCKS_PER_SAMPLE_HIGH : CLOCKS_PER_SAMPLE_LOW;

    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA  = 2'd2;
    localparam [1:0] STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] sample_clock_count;
    reg [3:0]  sample_phase;
    reg [1:0]  sample_sum;
    reg [2:0]  bit_index;
    reg [7:0]  data_shift;
    reg        rx_meta;
    reg        rx_sync;

    always @(posedge clk) begin
        if (reset) begin
            state              <= IDLE;
            sample_clock_count <= 16'd0;
            sample_phase       <= 4'd0;
            sample_sum         <= 2'd0;
            bit_index          <= 3'd0;
            data_shift         <= 8'd0;
            rx_data            <= 8'd0;
            rx_valid           <= 1'b0;
            rx_frame_error     <= 1'b0;
            rx_meta            <= 1'b1;
            rx_sync            <= 1'b1;
        end else begin
            rx_meta        <= rx;
            rx_sync        <= rx_meta;
            rx_valid       <= 1'b0;
            rx_frame_error <= 1'b0;

            if (state == IDLE) begin
                sample_clock_count <= 16'd0;
                sample_phase       <= 4'd0;
                sample_sum         <= 2'd0;
                bit_index          <= 3'd0;
                if (!rx_sync)
                    state <= START;
            end else if (sample_clock_count == clocks_per_sample - 1'b1) begin
                sample_clock_count <= 16'd0;

                // Samples 7, 8, and 9 of each 16-sample bit cell.
                if (sample_phase == 4'd6 || sample_phase == 4'd7 ||
                    sample_phase == 4'd8)
                    sample_sum <= sample_sum + rx_sync;

                if (sample_phase == 4'd15) begin
                    sample_phase <= 4'd0;
                    case (state)
                        START: begin
                            if (sample_sum < 2)
                                state <= DATA;
                            else
                                state <= IDLE;
                            sample_sum <= 2'd0;
                        end

                        DATA: begin
                            data_shift[bit_index] <= (sample_sum >= 2);
                            sample_sum <= 2'd0;
                            if (bit_index == 3'd7) begin
                                bit_index <= 3'd0;
                                state <= STOP;
                            end else begin
                                bit_index <= bit_index + 1'b1;
                            end
                        end

                        STOP: begin
                            state <= IDLE;
                            sample_sum <= 2'd0;
                            if (sample_sum >= 2) begin
                                rx_data  <= data_shift;
                                rx_valid <= 1'b1;
                            end else begin
                                rx_frame_error <= 1'b1;
                            end
                        end

                        default: state <= IDLE;
                    endcase
                end else begin
                    sample_phase <= sample_phase + 1'b1;
                end
            end else begin
                sample_clock_count <= sample_clock_count + 1'b1;
            end
        end
    end
endmodule
