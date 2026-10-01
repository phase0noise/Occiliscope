// Export a held copy of the VGA window. UART transmission never stalls VGA
// acquisition. Two adjacent VGA columns become one phone column, preserving
// both extrema and the mean. All enabled channels share the same time axis.
module scope_live (
    input wire clk, reset, request, frame_begin,
    input wire column_write,
    input wire [9:0] column_index,
    input wire [71:0] column_mean, column_min, column_max,
    input wire [5:0] column_valid,
    input wire [5:0] channel_mask,
    input wire [2:0] focus,
    input wire [3:0] timebase,
    input wire [1:0] scale, trigger_mode, trigger_position, average_mode,
    input wire [6:0] position,
    input wire grid, run, single_shot, stabilize, manual_mode,
    input wire [11:0] trigger_level,
    input wire [23:0] sample_period,
    input wire [15:0] full_scale_mv,
    input wire [9:0] valid_columns,
    output reg [7:0] tx_data,
    output wire tx_valid,
    input wire tx_pop
);
    reg pending, copying, sending;
    reg [5:0] mask, first_valid;
    reg [71:0] first_mean, first_min, first_max;
    reg [71:0] means [0:511] /* synthesis ramstyle = "M9K" */;
    reg [71:0] lows [0:511] /* synthesis ramstyle = "M9K" */;
    reg [71:0] highs [0:511] /* synthesis ramstyle = "M9K" */;
    reg [5:0] validity [0:511] /* synthesis ramstyle = "M9K" */;
    reg [71:0] read_mean, read_min, read_max;
    reg [5:0] read_valid;
    reg [7:0] header [0:31];
    reg [31:0] frame_id;
    reg [13:0] byte_index, packet_length;
    reg [8:0] read_column;
    reg [2:0] read_channel, field_index;
    reg mask_byte;
    reg [15:0] crc;
    wire [3:0] channel_count = {3'd0,channel_mask[0]} + {3'd0,channel_mask[1]} +
        {3'd0,channel_mask[2]} + {3'd0,channel_mask[3]} +
        {3'd0,channel_mask[4]} + {3'd0,channel_mask[5]};
    wire [13:0] length = 14'd34 + 14'd288 * (14'd1 + channel_count * 14'd6);
    integer ch;
    reg [12:0] pair_sum;
    reg [71:0] merged_mean, merged_min, merged_max;
    reg [11:0] value;

    function [2:0] first_channel;
        input [5:0] enabled;
        integer i;
        begin
            first_channel = 0;
            for (i=5; i>=0; i=i-1) if (enabled[i]) first_channel = i;
        end
    endfunction
    function [2:0] next_channel;
        input [5:0] enabled;
        input [2:0] current;
        integer i;
        begin
            next_channel = 6;
            for (i=5; i>=0; i=i-1)
                if (i > current && enabled[i]) next_channel = i;
        end
    endfunction
    function [15:0] crc_byte;
        input [15:0] previous;
        input [7:0] data;
        reg [15:0] work;
        integer bit_index;
        begin
            work = previous ^ {data,8'd0};
            for (bit_index=0; bit_index<8; bit_index=bit_index+1)
                work = work[15] ? (work << 1) ^ 16'h1021 : work << 1;
            crc_byte = work;
        end
    endfunction

    always @(posedge clk) begin
        read_mean <= means[read_column];
        read_min <= lows[read_column];
        read_max <= highs[read_column];
        read_valid <= validity[read_column];
    end
    assign tx_valid = sending;
    // One whole-word write per RAM is required for M9K inference. Writing
    // channel slices separately would turn this buffer into fabric registers.
    always @* begin
        pair_sum = 0;
        merged_mean = 0; merged_min = 0; merged_max = 0;
        for (ch=0; ch<6; ch=ch+1) begin
            pair_sum = {1'b0,first_mean[ch*12 +: 12]} +
                       {1'b0,column_mean[ch*12 +: 12]} + 13'd1;
            merged_mean[ch*12 +: 12] =
                !first_valid[ch] ? column_mean[ch*12 +: 12] :
                !column_valid[ch] ? first_mean[ch*12 +: 12] : pair_sum[12:1];
            merged_min[ch*12 +: 12] =
                !first_valid[ch] ? column_min[ch*12 +: 12] :
                !column_valid[ch] ? first_min[ch*12 +: 12] :
                first_min[ch*12 +: 12] < column_min[ch*12 +: 12] ?
                first_min[ch*12 +: 12] : column_min[ch*12 +: 12];
            merged_max[ch*12 +: 12] =
                !first_valid[ch] ? column_max[ch*12 +: 12] :
                !column_valid[ch] ? first_max[ch*12 +: 12] :
                first_max[ch*12 +: 12] > column_max[ch*12 +: 12] ?
                first_max[ch*12 +: 12] : column_max[ch*12 +: 12];
        end
    end
    always @* begin
        value = 0;
        case (field_index)
            0,1: value = read_mean[read_channel*12 +: 12];
            2,3: value = read_min[read_channel*12 +: 12];
            4,5: value = read_max[read_channel*12 +: 12];
            default: value = 0;
        endcase
        if (byte_index < 32) tx_data = header[byte_index[4:0]];
        else if (byte_index == packet_length-2) tx_data = crc[7:0];
        else if (byte_index == packet_length-1) tx_data = crc[15:8];
        else if (mask_byte) tx_data = {2'd0,read_valid};
        else tx_data = field_index[0] ? {4'd0,value[11:8]} : value[7:0];
    end

    always @(posedge clk) begin
        if (reset) begin
            pending <= 0; copying <= 0; sending <= 0;
            frame_id <= 0; byte_index <= 0; packet_length <= 0;
            read_column <= 0; read_channel <= 0; field_index <= 0;
            mask_byte <= 1; crc <= 16'hffff; mask <= 1;
        end else begin
            if (request && !copying && !sending) pending <= 1;
            if (frame_begin && pending && !copying && !sending) begin
                pending <= 0; copying <= 1; mask <= channel_mask;
                frame_id <= frame_id + 1'b1;
                packet_length <= length;
                header[0] <= 8'hd7; header[1] <= 1;
                header[2] <= length[7:0]; header[3] <= {2'd0,length[13:8]};
                header[4] <= {2'd0,channel_mask}; header[5] <= {5'd0,focus};
                header[6] <= {4'd0,timebase}; header[7] <= {6'd0,scale};
                header[8] <= {1'b0,position}; header[9] <= {6'd0,trigger_mode};
                header[10] <= {6'd0,trigger_position};
                header[11] <= {stabilize,average_mode,single_shot,trigger_position,run,grid};
                header[12] <= sample_period[7:0]; header[13] <= sample_period[15:8];
                header[14] <= sample_period[23:16]; header[15] <= 0;
                header[16] <= full_scale_mv[7:0]; header[17] <= full_scale_mv[15:8];
                header[18] <= 8'h20; header[19] <= 1; // 288 columns
                header[20] <= frame_id[7:0]; header[21] <= frame_id[15:8];
                header[22] <= frame_id[23:16]; header[23] <= frame_id[31:24];
                header[24] <= trigger_level[7:0]; header[25] <= {4'd0,trigger_level[11:8]};
                header[26] <= valid_columns[7:0]; header[27] <= {6'd0,valid_columns[9:8]};
                header[28] <= {7'd0,manual_mode}; header[29] <= 0; header[30] <= 0; header[31] <= 0;
            end
            if (copying && column_write) begin
                if (!column_index[0]) begin
                    first_mean <= column_mean; first_min <= column_min;
                    first_max <= column_max; first_valid <= column_valid;
                end else begin
                    validity[column_index[9:1]] <= first_valid | column_valid;
                    means[column_index[9:1]] <= merged_mean;
                    lows[column_index[9:1]] <= merged_min;
                    highs[column_index[9:1]] <= merged_max;
                    if (column_index == 575) begin
                        copying <= 0; sending <= 1; byte_index <= 0;
                        read_column <= 0; read_channel <= first_channel(mask);
                        field_index <= 0; mask_byte <= 1; crc <= 16'hffff;
                    end
                end
            end
            if (sending && tx_pop) begin
                if (byte_index < packet_length-2) crc <= crc_byte(crc,tx_data);
                if (byte_index == packet_length-1) sending <= 0;
                else byte_index <= byte_index + 1'b1;
                if (byte_index >= 32 && byte_index < packet_length-2) begin
                    if (mask_byte) mask_byte <= 0;
                    else if (field_index == 5) begin
                        field_index <= 0;
                        if (next_channel(mask,read_channel) == 6) begin
                            read_column <= read_column + 1'b1;
                            read_channel <= first_channel(mask); mask_byte <= 1;
                        end else read_channel <= next_channel(mask,read_channel);
                    end else field_index <= field_index + 1'b1;
                end
            end
        end
    end
endmodule
