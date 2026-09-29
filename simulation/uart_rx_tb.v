`timescale 1ns/1ps

module uart_rx_tb;
    localparam integer CLOCK_FREQ = 10000000;
    localparam integer BAUD_RATE = 9600;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg rx = 1'b1;
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_frame_error;
    integer received_count = 0;
    integer frame_error_count = 0;
    reg [7:0] received [0:2];

    always #50 clk = ~clk;

    uart_rx #(.CLOCK_FREQ(CLOCK_FREQ), .BAUD_RATE(BAUD_RATE)) dut (
        .clk(clk), .reset(reset), .high_speed(1'b0), .rx(rx), .rx_data(rx_data),
        .rx_valid(rx_valid), .rx_frame_error(rx_frame_error)
    );

    always @(posedge clk) begin
        if (rx_valid) begin
            if (received_count < 3)
                received[received_count] <= rx_data;
            received_count <= received_count + 1;
        end
        if (rx_frame_error)
            frame_error_count <= frame_error_count + 1;
    end

    task send_byte;
        input [7:0] value;
        input integer bit_time_ns;
        integer bit_number;
        begin
            rx = 1'b0;
            #(bit_time_ns);
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                rx = value[bit_number];
                #(bit_time_ns);
            end
            rx = 1'b1;
            #(bit_time_ns * 2);
        end
    endtask

    initial begin
        #1000;
        reset = 1'b0;
        #200000;

        // A short idle-line glitch must not create a byte.
        rx = 1'b0;
        #20000;
        rx = 1'b1;
        #200000;

        send_byte(8'hA5, 104167); // nominal baud
        send_byte(8'h3C, 101042); // transmitter approximately 3% fast
        send_byte(8'hF0, 107292); // transmitter approximately 3% slow
        #300000;

        if (received_count !== 3 || received[0] !== 8'hA5 ||
            received[1] !== 8'h3C || received[2] !== 8'hF0 ||
            frame_error_count !== 0) begin
            $display("FAIL count=%0d data=%02x,%02x,%02x frame_errors=%0d",
                     received_count, received[0], received[1], received[2], frame_error_count);
            $fatal(1);
        end

        $display("PASS: UART RX accepted nominal and +/-3%% baud with idle glitch rejection");
        $finish;
    end
endmodule
