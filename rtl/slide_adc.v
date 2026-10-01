// Minimal mixed-language bridge for the generated MAX 10 modular ADC IP.
// The channel input is synchronized into the ADC system-clock domain before
// it is presented to the streaming command interface.
module slide_adc (
    input         clk,
    input         reset_n,
    input  [4:0]  channel_select,
    output        adc_sys_clk,
    output        response_valid,
    output [4:0]  response_channel,
    output [11:0] response_data
);

    wire command_ready;
    wire response_startofpacket;
    wire response_endofpacket;
    reg [4:0] channel_select_meta;
    reg [4:0] channel_select_adc;

    always @(posedge adc_sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            channel_select_meta <= 5'd1;
            channel_select_adc <= 5'd1;
        end else begin
            channel_select_meta <= channel_select;
            channel_select_adc <= channel_select_meta;
        end
    end

    adc_qsys adc_ip (
        .clk_clk                              (clk),
        .clock_bridge_sys_out_clk_clk         (adc_sys_clk),
        .modular_adc_0_command_valid          (1'b1),
        .modular_adc_0_command_channel        (channel_select_adc),
        .modular_adc_0_command_startofpacket  (1'b1),
        .modular_adc_0_command_endofpacket    (1'b1),
        .modular_adc_0_command_ready          (command_ready),
        .modular_adc_0_response_valid         (response_valid),
        .modular_adc_0_response_channel       (response_channel),
        .modular_adc_0_response_data          (response_data),
        .modular_adc_0_response_startofpacket (response_startofpacket),
        .modular_adc_0_response_endofpacket   (response_endofpacket),
        .reset_reset_n                        (reset_n)
    );

endmodule
