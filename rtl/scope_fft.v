// A bounded, independent 256-point radix-2 FFT of the averaged focus stream.
// Capture -> remove DC -> Hann window -> bit-reversed, scaled FFT -> power bins.
// Three fractional bits preserve small signals through the eight scaled stages.
// Every butterfly divides by two, so the result is 8*FFT(input)/256. UART emits
// a CRC-protected D8 snapshot; VGA sampling and rendering are never paused.
module scope_fft (
    input wire clk, reset, request, cancel,
    input wire [3:0] requested_timebase,
    input wire [15:0] request_id,
    input wire [11:0] sample_data,
    input wire sample_strobe,
    input wire [2:0] channel,
    input wire [15:0] full_scale_mv,
    input wire [31:0] config_fingerprint,
    output wire busy,
    output reg [7:0] tx_data,
    output wire tx_valid,
    input wire tx_pop
);
    localparam IDLE=0, CAPTURE=1, PREP_ADDR=2, PREP_WAIT=3, PREP_MUL=4,
        PREP_WRITE=5, FFT_ADDR_A=6, FFT_WAIT_A=7, FFT_READ_A=8,
        FFT_WAIT_B=9, FFT_READ_B=10, FFT_MUL=11, FFT_ROTATE=12,
        FFT_WRITE_A=13, FFT_WRITE_B=14, FFT_NEXT=15, POWER_ADDR=16,
        POWER_WAIT=17, POWER_MUL=18, POWER_WRITE=19, HEADER=20, SEND=21, PERIOD=22;
    reg [4:0] state;
    reg [31:0] ticks, last_raw_tick, first_tick, previous_tick, duration, period;
    reg [31:0] fingerprint;
    reg [31:0] division_bits;
    reg [8:0] division_remainder;
    reg [5:0] division_count;
    wire [8:0] division_step = {division_remainder[7:0],division_bits[31]};
    wire division_bit = division_step >= 9'd255;
    wire [31:0] division_next = {division_bits[30:0],division_bit};
    reg [15:0] token, calibration;
    reg [2:0] focus;
    reg [3:0] timebase;
    reg [7:0] flags, capture_index, prep_index, power_index;
    reg [9:0] decimation_count;
    wire [9:0] decimation_limit = (10'd1 << timebase)-1'b1;
    reg [19:0] sample_sum;
    reg [11:0] dc_mean;
    reg [11:0] raw_memory [0:255] /* synthesis ramstyle = "M9K" */;
    reg [7:0] raw_address;
    reg [11:0] raw_read;
    reg signed [15:0] real_memory [0:255] /* synthesis ramstyle = "M9K" */;
    reg signed [15:0] imag_memory [0:255] /* synthesis ramstyle = "M9K" */;
    reg [7:0] read_address, write_address;
    reg write_enable;
    reg signed [15:0] read_real, read_imag, write_real, write_imag;
    reg signed [28:0] window_product;
    wire signed [12:0] centered_sample = $signed({1'b0,raw_read}) - $signed({1'b0,dc_mean});
    wire [6:0] hann_index = prep_index[7] ? ~prep_index[6:0] : prep_index[6:0];
    reg [3:0] stage;
    reg [8:0] group_base, offset;
    wire [8:0] half_size = 9'd1 << (stage-1'b1);
    wire [8:0] group_size = 9'd1 << stage;
    wire [8:0] address_a = group_base + offset;
    wire [8:0] address_b = address_a + half_size;
    wire [7:0] twiddle_index = offset << (8-stage);
    reg signed [15:0] ar, ai, br, bi, cosine, sine;
    reg signed [31:0] product_rc, product_is, product_rs, product_ic;
    wire signed [32:0] rotated_real_full = {product_rc[31],product_rc} - {product_is[31],product_is};
    wire signed [32:0] rotated_imag_full = {product_rs[31],product_rs} + {product_ic[31],product_ic};
    reg signed [17:0] rotated_real, rotated_imag;
    wire signed [18:0] sum_real = $signed(ar)+$signed(rotated_real);
    wire signed [18:0] sum_imag = $signed(ai)+$signed(rotated_imag);
    wire signed [18:0] difference_real = $signed(ar)-$signed(rotated_real);
    wire signed [18:0] difference_imag = $signed(ai)-$signed(rotated_imag);
    reg [31:0] squared_real, squared_imag;
    reg [31:0] power_memory [0:255] /* synthesis ramstyle = "M9K" */;
    reg [31:0] power_read;
    reg [7:0] header [0:31];
    reg [9:0] byte_index;
    wire [9:0] payload_offset = byte_index-10'd32;
    wire [7:0] power_address = byte_index >= 32 && byte_index < 548 ? payload_offset[9:2] : 8'd0;
    reg [15:0] crc;
    reg [1:0] tx_wait;
    wire [31:0] interval = ticks-previous_tick;
    wire [31:0] jitter_limit = period < 256 ? 32'd8 : period >> 5;
    assign busy = state != IDLE;
    assign tx_valid = state == SEND && tx_wait == 0;

    function [7:0] reverse_bits;
        input [7:0] index;
        begin reverse_bits={index[0],index[1],index[2],index[3],index[4],index[5],index[6],index[7]}; end
    endfunction
    function [15:0] crc_byte;
        input [15:0] current_crc;
        input [7:0] byte_value;
        reg [15:0] value;
        integer bit_index;
        begin
            value=current_crc ^ {byte_value,8'd0};
            for(bit_index=0;bit_index<8;bit_index=bit_index+1)
                value=value[15] ? (value<<1)^16'h1021 : value<<1;
            crc_byte=value;
        end
    endfunction
    function [15:0] hann;
        input [6:0] index;
        begin case(index)
            7'd0: hann=16'd0;
            7'd1: hann=16'd5;
            7'd2: hann=16'd20;
            7'd3: hann=16'd45;
            7'd4: hann=16'd80;
            7'd5: hann=16'd124;
            7'd6: hann=16'd179;
            7'd7: hann=16'd243;
            7'd8: hann=16'd317;
            7'd9: hann=16'd401;
            7'd10: hann=16'd495;
            7'd11: hann=16'd598;
            7'd12: hann=16'd711;
            7'd13: hann=16'd833;
            7'd14: hann=16'd965;
            7'd15: hann=16'd1106;
            7'd16: hann=16'd1257;
            7'd17: hann=16'd1416;
            7'd18: hann=16'd1585;
            7'd19: hann=16'd1763;
            7'd20: hann=16'd1949;
            7'd21: hann=16'd2145;
            7'd22: hann=16'd2349;
            7'd23: hann=16'd2561;
            7'd24: hann=16'd2782;
            7'd25: hann=16'd3011;
            7'd26: hann=16'd3249;
            7'd27: hann=16'd3494;
            7'd28: hann=16'd3747;
            7'd29: hann=16'd4008;
            7'd30: hann=16'd4276;
            7'd31: hann=16'd4552;
            7'd32: hann=16'd4834;
            7'd33: hann=16'd5124;
            7'd34: hann=16'd5421;
            7'd35: hann=16'd5724;
            7'd36: hann=16'd6034;
            7'd37: hann=16'd6350;
            7'd38: hann=16'd6672;
            7'd39: hann=16'd7000;
            7'd40: hann=16'd7334;
            7'd41: hann=16'd7673;
            7'd42: hann=16'd8018;
            7'd43: hann=16'd8367;
            7'd44: hann=16'd8722;
            7'd45: hann=16'd9081;
            7'd46: hann=16'd9444;
            7'd47: hann=16'd9812;
            7'd48: hann=16'd10184;
            7'd49: hann=16'd10559;
            7'd50: hann=16'd10938;
            7'd51: hann=16'd11321;
            7'd52: hann=16'd11706;
            7'd53: hann=16'd12094;
            7'd54: hann=16'd12485;
            7'd55: hann=16'd12879;
            7'd56: hann=16'd13274;
            7'd57: hann=16'd13671;
            7'd58: hann=16'd14070;
            7'd59: hann=16'd14470;
            7'd60: hann=16'd14872;
            7'd61: hann=16'd15274;
            7'd62: hann=16'd15677;
            7'd63: hann=16'd16081;
            7'd64: hann=16'd16484;
            7'd65: hann=16'd16888;
            7'd66: hann=16'd17291;
            7'd67: hann=16'd17694;
            7'd68: hann=16'd18096;
            7'd69: hann=16'd18497;
            7'd70: hann=16'd18897;
            7'd71: hann=16'd19295;
            7'd72: hann=16'd19691;
            7'd73: hann=16'd20085;
            7'd74: hann=16'd20477;
            7'd75: hann=16'd20867;
            7'd76: hann=16'd21254;
            7'd77: hann=16'd21638;
            7'd78: hann=16'd22019;
            7'd79: hann=16'd22396;
            7'd80: hann=16'd22770;
            7'd81: hann=16'd23139;
            7'd82: hann=16'd23505;
            7'd83: hann=16'd23866;
            7'd84: hann=16'd24223;
            7'd85: hann=16'd24575;
            7'd86: hann=16'd24922;
            7'd87: hann=16'd25264;
            7'd88: hann=16'd25601;
            7'd89: hann=16'd25932;
            7'd90: hann=16'd26257;
            7'd91: hann=16'd26576;
            7'd92: hann=16'd26889;
            7'd93: hann=16'd27195;
            7'd94: hann=16'd27495;
            7'd95: hann=16'd27789;
            7'd96: hann=16'd28075;
            7'd97: hann=16'd28354;
            7'd98: hann=16'd28626;
            7'd99: hann=16'd28891;
            7'd100: hann=16'd29148;
            7'd101: hann=16'd29397;
            7'd102: hann=16'd29638;
            7'd103: hann=16'd29871;
            7'd104: hann=16'd30096;
            7'd105: hann=16'd30313;
            7'd106: hann=16'd30521;
            7'd107: hann=16'd30721;
            7'd108: hann=16'd30912;
            7'd109: hann=16'd31094;
            7'd110: hann=16'd31267;
            7'd111: hann=16'd31432;
            7'd112: hann=16'd31587;
            7'd113: hann=16'd31732;
            7'd114: hann=16'd31869;
            7'd115: hann=16'd31996;
            7'd116: hann=16'd32114;
            7'd117: hann=16'd32222;
            7'd118: hann=16'd32320;
            7'd119: hann=16'd32409;
            7'd120: hann=16'd32488;
            7'd121: hann=16'd32557;
            7'd122: hann=16'd32617;
            7'd123: hann=16'd32666;
            7'd124: hann=16'd32706;
            7'd125: hann=16'd32736;
            7'd126: hann=16'd32756;
            7'd127: hann=16'd32766;
            default:hann=0;
        endcase end
    endfunction
    function signed [15:0] twiddle_cos;
        input [6:0] index;
        begin case(index)
            7'd0: twiddle_cos=16'sd32767;
            7'd1: twiddle_cos=16'sd32757;
            7'd2: twiddle_cos=16'sd32728;
            7'd3: twiddle_cos=16'sd32678;
            7'd4: twiddle_cos=16'sd32609;
            7'd5: twiddle_cos=16'sd32521;
            7'd6: twiddle_cos=16'sd32412;
            7'd7: twiddle_cos=16'sd32285;
            7'd8: twiddle_cos=16'sd32137;
            7'd9: twiddle_cos=16'sd31971;
            7'd10: twiddle_cos=16'sd31785;
            7'd11: twiddle_cos=16'sd31580;
            7'd12: twiddle_cos=16'sd31356;
            7'd13: twiddle_cos=16'sd31113;
            7'd14: twiddle_cos=16'sd30852;
            7'd15: twiddle_cos=16'sd30571;
            7'd16: twiddle_cos=16'sd30273;
            7'd17: twiddle_cos=16'sd29956;
            7'd18: twiddle_cos=16'sd29621;
            7'd19: twiddle_cos=16'sd29268;
            7'd20: twiddle_cos=16'sd28898;
            7'd21: twiddle_cos=16'sd28510;
            7'd22: twiddle_cos=16'sd28105;
            7'd23: twiddle_cos=16'sd27683;
            7'd24: twiddle_cos=16'sd27245;
            7'd25: twiddle_cos=16'sd26790;
            7'd26: twiddle_cos=16'sd26319;
            7'd27: twiddle_cos=16'sd25832;
            7'd28: twiddle_cos=16'sd25329;
            7'd29: twiddle_cos=16'sd24811;
            7'd30: twiddle_cos=16'sd24279;
            7'd31: twiddle_cos=16'sd23731;
            7'd32: twiddle_cos=16'sd23170;
            7'd33: twiddle_cos=16'sd22594;
            7'd34: twiddle_cos=16'sd22005;
            7'd35: twiddle_cos=16'sd21403;
            7'd36: twiddle_cos=16'sd20787;
            7'd37: twiddle_cos=16'sd20159;
            7'd38: twiddle_cos=16'sd19519;
            7'd39: twiddle_cos=16'sd18868;
            7'd40: twiddle_cos=16'sd18204;
            7'd41: twiddle_cos=16'sd17530;
            7'd42: twiddle_cos=16'sd16846;
            7'd43: twiddle_cos=16'sd16151;
            7'd44: twiddle_cos=16'sd15446;
            7'd45: twiddle_cos=16'sd14732;
            7'd46: twiddle_cos=16'sd14010;
            7'd47: twiddle_cos=16'sd13279;
            7'd48: twiddle_cos=16'sd12539;
            7'd49: twiddle_cos=16'sd11793;
            7'd50: twiddle_cos=16'sd11039;
            7'd51: twiddle_cos=16'sd10278;
            7'd52: twiddle_cos=16'sd9512;
            7'd53: twiddle_cos=16'sd8739;
            7'd54: twiddle_cos=16'sd7962;
            7'd55: twiddle_cos=16'sd7179;
            7'd56: twiddle_cos=16'sd6393;
            7'd57: twiddle_cos=16'sd5602;
            7'd58: twiddle_cos=16'sd4808;
            7'd59: twiddle_cos=16'sd4011;
            7'd60: twiddle_cos=16'sd3212;
            7'd61: twiddle_cos=16'sd2410;
            7'd62: twiddle_cos=16'sd1608;
            7'd63: twiddle_cos=16'sd804;
            7'd64: twiddle_cos=16'sd0;
            7'd65: twiddle_cos=-16'sd804;
            7'd66: twiddle_cos=-16'sd1608;
            7'd67: twiddle_cos=-16'sd2410;
            7'd68: twiddle_cos=-16'sd3212;
            7'd69: twiddle_cos=-16'sd4011;
            7'd70: twiddle_cos=-16'sd4808;
            7'd71: twiddle_cos=-16'sd5602;
            7'd72: twiddle_cos=-16'sd6393;
            7'd73: twiddle_cos=-16'sd7179;
            7'd74: twiddle_cos=-16'sd7962;
            7'd75: twiddle_cos=-16'sd8739;
            7'd76: twiddle_cos=-16'sd9512;
            7'd77: twiddle_cos=-16'sd10278;
            7'd78: twiddle_cos=-16'sd11039;
            7'd79: twiddle_cos=-16'sd11793;
            7'd80: twiddle_cos=-16'sd12539;
            7'd81: twiddle_cos=-16'sd13279;
            7'd82: twiddle_cos=-16'sd14010;
            7'd83: twiddle_cos=-16'sd14732;
            7'd84: twiddle_cos=-16'sd15446;
            7'd85: twiddle_cos=-16'sd16151;
            7'd86: twiddle_cos=-16'sd16846;
            7'd87: twiddle_cos=-16'sd17530;
            7'd88: twiddle_cos=-16'sd18204;
            7'd89: twiddle_cos=-16'sd18868;
            7'd90: twiddle_cos=-16'sd19519;
            7'd91: twiddle_cos=-16'sd20159;
            7'd92: twiddle_cos=-16'sd20787;
            7'd93: twiddle_cos=-16'sd21403;
            7'd94: twiddle_cos=-16'sd22005;
            7'd95: twiddle_cos=-16'sd22594;
            7'd96: twiddle_cos=-16'sd23170;
            7'd97: twiddle_cos=-16'sd23731;
            7'd98: twiddle_cos=-16'sd24279;
            7'd99: twiddle_cos=-16'sd24811;
            7'd100: twiddle_cos=-16'sd25329;
            7'd101: twiddle_cos=-16'sd25832;
            7'd102: twiddle_cos=-16'sd26319;
            7'd103: twiddle_cos=-16'sd26790;
            7'd104: twiddle_cos=-16'sd27245;
            7'd105: twiddle_cos=-16'sd27683;
            7'd106: twiddle_cos=-16'sd28105;
            7'd107: twiddle_cos=-16'sd28510;
            7'd108: twiddle_cos=-16'sd28898;
            7'd109: twiddle_cos=-16'sd29268;
            7'd110: twiddle_cos=-16'sd29621;
            7'd111: twiddle_cos=-16'sd29956;
            7'd112: twiddle_cos=-16'sd30273;
            7'd113: twiddle_cos=-16'sd30571;
            7'd114: twiddle_cos=-16'sd30852;
            7'd115: twiddle_cos=-16'sd31113;
            7'd116: twiddle_cos=-16'sd31356;
            7'd117: twiddle_cos=-16'sd31580;
            7'd118: twiddle_cos=-16'sd31785;
            7'd119: twiddle_cos=-16'sd31971;
            7'd120: twiddle_cos=-16'sd32137;
            7'd121: twiddle_cos=-16'sd32285;
            7'd122: twiddle_cos=-16'sd32412;
            7'd123: twiddle_cos=-16'sd32521;
            7'd124: twiddle_cos=-16'sd32609;
            7'd125: twiddle_cos=-16'sd32678;
            7'd126: twiddle_cos=-16'sd32728;
            7'd127: twiddle_cos=-16'sd32757;
            default:twiddle_cos=0;
        endcase end
    endfunction
    function signed [15:0] twiddle_sin;
        input [6:0] index;
        begin case(index)
            7'd0: twiddle_sin=16'sd0;
            7'd1: twiddle_sin=-16'sd804;
            7'd2: twiddle_sin=-16'sd1608;
            7'd3: twiddle_sin=-16'sd2410;
            7'd4: twiddle_sin=-16'sd3212;
            7'd5: twiddle_sin=-16'sd4011;
            7'd6: twiddle_sin=-16'sd4808;
            7'd7: twiddle_sin=-16'sd5602;
            7'd8: twiddle_sin=-16'sd6393;
            7'd9: twiddle_sin=-16'sd7179;
            7'd10: twiddle_sin=-16'sd7962;
            7'd11: twiddle_sin=-16'sd8739;
            7'd12: twiddle_sin=-16'sd9512;
            7'd13: twiddle_sin=-16'sd10278;
            7'd14: twiddle_sin=-16'sd11039;
            7'd15: twiddle_sin=-16'sd11793;
            7'd16: twiddle_sin=-16'sd12539;
            7'd17: twiddle_sin=-16'sd13279;
            7'd18: twiddle_sin=-16'sd14010;
            7'd19: twiddle_sin=-16'sd14732;
            7'd20: twiddle_sin=-16'sd15446;
            7'd21: twiddle_sin=-16'sd16151;
            7'd22: twiddle_sin=-16'sd16846;
            7'd23: twiddle_sin=-16'sd17530;
            7'd24: twiddle_sin=-16'sd18204;
            7'd25: twiddle_sin=-16'sd18868;
            7'd26: twiddle_sin=-16'sd19519;
            7'd27: twiddle_sin=-16'sd20159;
            7'd28: twiddle_sin=-16'sd20787;
            7'd29: twiddle_sin=-16'sd21403;
            7'd30: twiddle_sin=-16'sd22005;
            7'd31: twiddle_sin=-16'sd22594;
            7'd32: twiddle_sin=-16'sd23170;
            7'd33: twiddle_sin=-16'sd23731;
            7'd34: twiddle_sin=-16'sd24279;
            7'd35: twiddle_sin=-16'sd24811;
            7'd36: twiddle_sin=-16'sd25329;
            7'd37: twiddle_sin=-16'sd25832;
            7'd38: twiddle_sin=-16'sd26319;
            7'd39: twiddle_sin=-16'sd26790;
            7'd40: twiddle_sin=-16'sd27245;
            7'd41: twiddle_sin=-16'sd27683;
            7'd42: twiddle_sin=-16'sd28105;
            7'd43: twiddle_sin=-16'sd28510;
            7'd44: twiddle_sin=-16'sd28898;
            7'd45: twiddle_sin=-16'sd29268;
            7'd46: twiddle_sin=-16'sd29621;
            7'd47: twiddle_sin=-16'sd29956;
            7'd48: twiddle_sin=-16'sd30273;
            7'd49: twiddle_sin=-16'sd30571;
            7'd50: twiddle_sin=-16'sd30852;
            7'd51: twiddle_sin=-16'sd31113;
            7'd52: twiddle_sin=-16'sd31356;
            7'd53: twiddle_sin=-16'sd31580;
            7'd54: twiddle_sin=-16'sd31785;
            7'd55: twiddle_sin=-16'sd31971;
            7'd56: twiddle_sin=-16'sd32137;
            7'd57: twiddle_sin=-16'sd32285;
            7'd58: twiddle_sin=-16'sd32412;
            7'd59: twiddle_sin=-16'sd32521;
            7'd60: twiddle_sin=-16'sd32609;
            7'd61: twiddle_sin=-16'sd32678;
            7'd62: twiddle_sin=-16'sd32728;
            7'd63: twiddle_sin=-16'sd32757;
            7'd64: twiddle_sin=-16'sd32767;
            7'd65: twiddle_sin=-16'sd32757;
            7'd66: twiddle_sin=-16'sd32728;
            7'd67: twiddle_sin=-16'sd32678;
            7'd68: twiddle_sin=-16'sd32609;
            7'd69: twiddle_sin=-16'sd32521;
            7'd70: twiddle_sin=-16'sd32412;
            7'd71: twiddle_sin=-16'sd32285;
            7'd72: twiddle_sin=-16'sd32137;
            7'd73: twiddle_sin=-16'sd31971;
            7'd74: twiddle_sin=-16'sd31785;
            7'd75: twiddle_sin=-16'sd31580;
            7'd76: twiddle_sin=-16'sd31356;
            7'd77: twiddle_sin=-16'sd31113;
            7'd78: twiddle_sin=-16'sd30852;
            7'd79: twiddle_sin=-16'sd30571;
            7'd80: twiddle_sin=-16'sd30273;
            7'd81: twiddle_sin=-16'sd29956;
            7'd82: twiddle_sin=-16'sd29621;
            7'd83: twiddle_sin=-16'sd29268;
            7'd84: twiddle_sin=-16'sd28898;
            7'd85: twiddle_sin=-16'sd28510;
            7'd86: twiddle_sin=-16'sd28105;
            7'd87: twiddle_sin=-16'sd27683;
            7'd88: twiddle_sin=-16'sd27245;
            7'd89: twiddle_sin=-16'sd26790;
            7'd90: twiddle_sin=-16'sd26319;
            7'd91: twiddle_sin=-16'sd25832;
            7'd92: twiddle_sin=-16'sd25329;
            7'd93: twiddle_sin=-16'sd24811;
            7'd94: twiddle_sin=-16'sd24279;
            7'd95: twiddle_sin=-16'sd23731;
            7'd96: twiddle_sin=-16'sd23170;
            7'd97: twiddle_sin=-16'sd22594;
            7'd98: twiddle_sin=-16'sd22005;
            7'd99: twiddle_sin=-16'sd21403;
            7'd100: twiddle_sin=-16'sd20787;
            7'd101: twiddle_sin=-16'sd20159;
            7'd102: twiddle_sin=-16'sd19519;
            7'd103: twiddle_sin=-16'sd18868;
            7'd104: twiddle_sin=-16'sd18204;
            7'd105: twiddle_sin=-16'sd17530;
            7'd106: twiddle_sin=-16'sd16846;
            7'd107: twiddle_sin=-16'sd16151;
            7'd108: twiddle_sin=-16'sd15446;
            7'd109: twiddle_sin=-16'sd14732;
            7'd110: twiddle_sin=-16'sd14010;
            7'd111: twiddle_sin=-16'sd13279;
            7'd112: twiddle_sin=-16'sd12539;
            7'd113: twiddle_sin=-16'sd11793;
            7'd114: twiddle_sin=-16'sd11039;
            7'd115: twiddle_sin=-16'sd10278;
            7'd116: twiddle_sin=-16'sd9512;
            7'd117: twiddle_sin=-16'sd8739;
            7'd118: twiddle_sin=-16'sd7962;
            7'd119: twiddle_sin=-16'sd7179;
            7'd120: twiddle_sin=-16'sd6393;
            7'd121: twiddle_sin=-16'sd5602;
            7'd122: twiddle_sin=-16'sd4808;
            7'd123: twiddle_sin=-16'sd4011;
            7'd124: twiddle_sin=-16'sd3212;
            7'd125: twiddle_sin=-16'sd2410;
            7'd126: twiddle_sin=-16'sd1608;
            7'd127: twiddle_sin=-16'sd804;
            default:twiddle_sin=0;
        endcase end
    endfunction
    // RAM reads are synchronous. Each read gets an address and a wait cycle;
    // butterfly writes are serialized to keep one write port per component.
    always @(posedge clk) begin
        raw_read <= raw_memory[raw_address];
        read_real <= real_memory[read_address];
        read_imag <= imag_memory[read_address];
        power_read <= power_memory[power_address];
        if(write_enable) begin
            real_memory[write_address] <= write_real;
            imag_memory[write_address] <= write_imag;
        end
    end
    always @* begin
        if(byte_index < 32) tx_data=header[byte_index[4:0]];
        else if(byte_index == 548) tx_data=crc[7:0];
        else if(byte_index == 549) tx_data=crc[15:8];
        else if(!flags[0]) tx_data=0;
        else case(payload_offset[1:0])
            0:tx_data=power_read[7:0]; 1:tx_data=power_read[15:8];
            2:tx_data=power_read[23:16]; 3:tx_data=power_read[31:24];
        endcase
    end
    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;ticks<=0;write_enable<=0;tx_wait<=0;byte_index<=0;
            raw_address<=0;read_address<=0;write_address<=0;
            write_real<=0;write_imag<=0;crc<=16'hffff;
            flags<=0;capture_index<=0;prep_index<=0;power_index<=0;
            stage<=1;group_base<=0;offset<=0;period<=0;duration<=0;dc_mean<=0;
        end else begin
            ticks<=ticks+1'b1;
            write_enable<=0;
            case(state)
                IDLE: if(request) begin
                    token<=request_id;focus<=channel;calibration<=full_scale_mv;
                    fingerprint<=config_fingerprint;timebase<=requested_timebase;
                    capture_index<=0;decimation_count<=0;sample_sum<=0;
                    flags<=1;period<=0;duration<=0;dc_mean<=0;
                    last_raw_tick<=ticks;state<=CAPTURE;
                end
                CAPTURE: begin
                    if(cancel || config_fingerprint != fingerprint || ticks-last_raw_tick > 100000000) begin
                        flags<=cancel ? 8'h10 : config_fingerprint != fingerprint ? 8'h02 : 8'h08;
                        state<=HEADER;
                    end else if(sample_strobe) begin
                        last_raw_tick<=ticks;
                        if(decimation_count != decimation_limit)
                            decimation_count<=decimation_count+1'b1;
                        else begin
                            decimation_count<=0;
                            raw_memory[capture_index]<=sample_data;
                            sample_sum<=sample_sum+sample_data;
                            previous_tick<=ticks;
                            if(capture_index == 0) first_tick<=ticks;
                            else if(capture_index == 1) period<=interval;
                            else if(interval > period+jitter_limit || interval+jitter_limit < period)
                                flags<=8'h04;
                            if(capture_index == 255) begin
                                dc_mean<=(sample_sum+sample_data+20'd128)>>8;
                                duration<=ticks-first_tick;
                                // Divide the elapsed ticks over 32 short cycles.
                                // Keep a wide divider off the ADC capture path.
                                division_bits<=ticks-first_tick+32'd127;
                                division_remainder<=0;division_count<=32;
                                prep_index<=0;state<=PERIOD;
                            end else capture_index<=capture_index+1'b1;
                        end
                    end
                end
                PERIOD: begin
                    division_bits<=division_next;
                    division_remainder<=division_bit ? division_step-9'd255 : division_step;
                    division_count<=division_count-1'b1;
                    if(division_count==1)begin period<=division_next;state<=PREP_ADDR;end
                end
                PREP_ADDR: begin raw_address<=prep_index;state<=PREP_WAIT;end
                PREP_WAIT: state<=PREP_MUL;
                PREP_MUL: begin window_product<=centered_sample * $signed({1'b0,hann(hann_index)});state<=PREP_WRITE;end
                PREP_WRITE: begin
                    write_enable<=1;write_address<=reverse_bits(prep_index);
                    write_real<=window_product>>>12;write_imag<=0;
                    if(prep_index == 255) begin stage<=1;group_base<=0;offset<=0;state<=FFT_ADDR_A;end
                    else begin prep_index<=prep_index+1'b1;state<=PREP_ADDR;end
                end
                FFT_ADDR_A: begin read_address<=address_a[7:0];state<=FFT_WAIT_A;end
                FFT_WAIT_A: state<=FFT_READ_A;
                FFT_READ_A: begin ar<=read_real;ai<=read_imag;read_address<=address_b[7:0];state<=FFT_WAIT_B;end
                FFT_WAIT_B: state<=FFT_READ_B;
                FFT_READ_B: begin br<=read_real;bi<=read_imag;cosine<=twiddle_cos(twiddle_index[6:0]);sine<=twiddle_sin(twiddle_index[6:0]);state<=FFT_MUL;end
                FFT_MUL: begin
                    product_rc<=br*cosine;product_is<=bi*sine;
                    product_rs<=br*sine;product_ic<=bi*cosine;state<=FFT_ROTATE;
                end
                FFT_ROTATE: begin rotated_real<=rotated_real_full>>>15;rotated_imag<=rotated_imag_full>>>15;state<=FFT_WRITE_A;end
                FFT_WRITE_A: begin
                    write_enable<=1;write_address<=address_a[7:0];write_real<=sum_real>>>1;write_imag<=sum_imag>>>1;state<=FFT_WRITE_B;
                end
                FFT_WRITE_B: begin
                    write_enable<=1;write_address<=address_b[7:0];write_real<=difference_real>>>1;write_imag<=difference_imag>>>1;state<=FFT_NEXT;
                end
                FFT_NEXT: begin
                    if(offset+1 < half_size) offset<=offset+1'b1;
                    else begin
                        offset<=0;
                        if(group_base+group_size < 256) group_base<=group_base+group_size;
                        else begin
                            group_base<=0;
                            if(stage == 8) begin power_index<=0;state<=POWER_ADDR;end
                            else stage<=stage+1'b1;
                        end
                    end
                    if(!(stage == 8 && offset+1 == half_size && group_base+group_size == 256)) state<=FFT_ADDR_A;
                end
                POWER_ADDR: begin read_address<=power_index;state<=POWER_WAIT;end
                POWER_WAIT: state<=POWER_MUL;
                POWER_MUL: begin squared_real<=read_real*read_real;squared_imag<=read_imag*read_imag;state<=POWER_WRITE;end
                POWER_WRITE: begin
                    power_memory[power_index]<=squared_real+squared_imag;
                    if(power_index == 128) state<=HEADER;
                    else begin power_index<=power_index+1'b1;state<=POWER_ADDR;end
                end
                HEADER: begin
                    header[0]<=8'hd8;header[1]<=1;header[2]<=8'h26;header[3]<=2;
                    header[4]<=flags;header[5]<={5'd0,focus};header[6]<=8;header[7]<={4'd0,timebase};
                    header[8]<=token[7:0];header[9]<=token[15:8];header[10]<=0;header[11]<=0;
                    header[12]<=period[7:0];header[13]<=period[15:8];header[14]<=period[23:16];header[15]<=period[31:24];
                    header[16]<=calibration[7:0];header[17]<=calibration[15:8];header[18]<=0;header[19]<=1;
                    header[20]<=duration[7:0];header[21]<=duration[15:8];header[22]<=duration[23:16];header[23]<=duration[31:24];
                    header[24]<=dc_mean[7:0];header[25]<={4'd0,dc_mean[11:8]};
                    header[26]<=8'hc0;header[27]<=8'h3f; // Hann coherent gain 16320/32768
                    header[28]<=129;header[29]<=0;header[30]<=1;header[31]<=3; // fractional bits
                    byte_index<=0;crc<=16'hffff;tx_wait<=2;state<=SEND;
                end
                SEND: begin
                    if(tx_wait != 0) tx_wait<=tx_wait-1'b1;
                    else if(tx_pop) begin
                        if(byte_index < 548) crc<=crc_byte(crc,tx_data);
                        if(byte_index == 549) state<=IDLE;
                        else begin byte_index<=byte_index+1'b1;tx_wait<=2;end
                    end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
