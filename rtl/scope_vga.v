// 640x480 @ 60 Hz oscilloscope display for the DE10-Lite VGA connector.
//
// Everything runs from the board's 50 MHz clock.  A clock enable advances the
// 25 MHz VGA pixel state, avoiding a fabric-generated clock.  The waveform RAM
// is a same-clock, simple dual-port memory and maps cleanly into MAX 10 M9Ks.
module scope_vga (
    input  wire        clk,
    input  wire        reset,
    input  wire [11:0] sample_data,
    input  wire        sample_strobe,
    input  wire [11:0] scan_sample_data,
    input  wire        scan_sample_strobe,
    input  wire [2:0]  scan_sample_channel,
    input  wire [2:0]  channel,
    input  wire [5:0]  channel_mask,
    input  wire [71:0] channel_samples,
    input  wire [3:0]  timebase,
    input  wire [1:0]  vertical_scale,
    input  wire [6:0]  vertical_position,
    input  wire [1:0]  trigger_mode,       // 0 free, 1 rising, 2 falling, 3 auto-rise
    input  wire [11:0] trigger_level,
    input  wire        grid_enable,
    input  wire        run_enable,
    input  wire        manual_mode,
    input  wire [1:0]  trigger_position,
    input  wire        single_shot,
    input  wire [1:0]  average_mode,
    input  wire        stabilize_enable,
    input  wire [23:0] sample_period_cycles,
    input  wire [15:0] full_scale_mv,
    input  wire        live_request,
    input  wire        live_metadata_request,
    output wire [7:0]  live_tx_data,
    output wire        live_tx_valid,
    input  wire        live_tx_pop,
    output reg  [3:0]  VGA_R,
    output reg  [3:0]  VGA_G,
    output reg  [3:0]  VGA_B,
    output reg         VGA_HS,
    output reg         VGA_VS
);
    localparam integer H_VISIBLE = 640;
    localparam integer H_FRONT   = 16;
    localparam integer H_SYNC    = 96;
    localparam integer H_TOTAL   = 800;
    localparam integer V_VISIBLE = 480;
    localparam integer V_FRONT   = 10;
    localparam integer V_SYNC    = 2;
    localparam integer V_TOTAL   = 525;

    localparam integer PLOT_LEFT   = 40;
    localparam integer PLOT_RIGHT  = 615;
    localparam [9:0] PLOT_TOP      = 10'd42;
    localparam [9:0] PLOT_BOTTOM   = 10'd377;
    localparam integer PLOT_WIDTH  = PLOT_RIGHT - PLOT_LEFT + 1; // 576 samples
    wire [9:0] pretrigger_samples = trigger_position == 2'd0 ? 10'd58 :
                                    trigger_position == 2'd1 ? 10'd144 :
                                    trigger_position == 2'd2 ? 10'd288 : 10'd432;

    reg pixel_phase;
    reg [9:0] h_count;
    reg [9:0] v_count;
    reg [9:0] h_pipe;
    reg [9:0] v_pipe;
    reg [9:0] h_render;
    reg [9:0] v_render;
    reg [9:0] h_display;
    reg [9:0] v_display;
    reg [2:0] render_channel;
    reg [5:0] render_channel_mask;
    reg [71:0] render_channel_samples;
    reg [3:0] render_timebase;
    reg [1:0] render_vertical_scale;
    reg [6:0] render_vertical_position;
    reg [1:0] render_trigger_mode;
    reg [11:0] render_trigger_level;
    reg render_grid_enable;
    reg render_run_enable;
    reg render_manual_mode;
    reg [1:0] render_trigger_position;
    reg render_single_shot;
    reg [1:0] render_average_mode;
    reg render_stabilize_enable;
    reg [15:0] render_full_scale_mv;
    reg [31:0] render_time_div_us;
    reg [15:0] display_adc_bcd, display_now_bcd, display_min_bcd, display_max_bcd;
    reg [15:0] display_pp_bcd, display_avg_bcd, display_level_bcd;
    reg [15:0] display_vdiv_bcd;
    reg [15:0] display_axis_top_bcd, display_axis_upper_bcd;
    reg [15:0] display_axis_mid_bcd, display_axis_lower_bcd, display_axis_bottom_bcd;
    reg [31:0] display_time_bcd;
    reg [31:0] display_axis_mid_time_bcd, display_axis_end_time_bcd;
    reg [29:0] bcd_adc_shift, bcd_now_shift, bcd_min_shift, bcd_max_shift;
    reg [29:0] bcd_pp_shift, bcd_avg_shift, bcd_level_shift, bcd_vdiv_shift;
    reg [29:0] bcd_axis_top_shift, bcd_axis_upper_shift, bcd_axis_mid_shift;
    reg [29:0] bcd_axis_lower_shift, bcd_axis_bottom_shift;
    reg [55:0] bcd_time_shift;
    reg [55:0] bcd_axis_mid_time_shift, bcd_axis_end_time_shift;
    reg [5:0] display_bcd_count;
    reg [29:0] channel_voltage_shift [0:5];
    reg [15:0] channel_voltage_bcd [0:5];
    wire [27:0] channel_mv_product [0:5];
    integer voltage_index;
    genvar voltage_ch;
    generate for (voltage_ch=0; voltage_ch<6; voltage_ch=voltage_ch+1) begin: header_voltage
        assign channel_mv_product[voltage_ch] =
            render_channel_samples[voltage_ch*12 +: 12] * render_full_scale_mv;
    end endgenerate

    // Quartus recognizes this as a 1024 x 12 simple dual-port RAM.
    reg [11:0] sample_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [11:0] sample_min_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [11:0] sample_max_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    // The acquisition ring is written much faster than a VGA frame is scanned.
    // Copy the visible window into a dedicated frame buffer during vertical
    // blanking so every scanline renders the exact same waveform snapshot.
    reg [11:0] frame_sample_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [11:0] frame_min_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [11:0] frame_max_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    // Every focus sample also records the latest reading from all six inputs.
    // A shared address keeps their VGA time axes aligned with the trigger.
    reg [71:0] channel_trace_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [71:0] frame_channel_trace_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [71:0] channel_min_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [71:0] channel_max_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [71:0] frame_channel_min_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [71:0] frame_channel_max_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [5:0] channel_valid_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [5:0] frame_channel_valid_memory [0:1023] /* synthesis ramstyle = "M9K" */;
    reg [9:0] write_pointer;
    reg [9:0] display_start;
    reg [9:0] read_address;
    reg [11:0] read_sample;
    reg [11:0] read_min_sample;
    reg [11:0] read_max_sample;
    reg [71:0] read_channel_traces;
    reg [71:0] read_channel_min;
    reg [71:0] read_channel_max;
    reg [5:0] read_channel_valid;

    reg [9:0] decimation_count;
    wire [9:0] decimation_limit = (10'd1 << timebase) - 1'b1;
    reg snapshot_copy_active;
    reg snapshot_copy_valid;
    reg frame_snapshot_ready;
    reg triggered_snapshot_ready;
    reg capture_was_triggered;
    reg [9:0] snapshot_start;
    reg [9:0] snapshot_read_address;
    reg [9:0] snapshot_copy_index;
    reg [11:0] snapshot_sample;
    reg [11:0] snapshot_min_sample;
    reg [11:0] snapshot_max_sample;
    reg [71:0] snapshot_channel_traces;
    reg [71:0] snapshot_channel_min;
    reg [71:0] snapshot_channel_max;
    reg [5:0] snapshot_channel_valid;
    reg [71:0] channel_min_work;
    reg [71:0] channel_max_work;
    reg [21:0] channel_sum_work [0:5];
    reg [10:0] channel_count_work [0:5];
    reg [5:0] channel_seen_work;
    reg [5:0] channel_seen_since_selection;
    reg [5:0] render_seen_mask;
    reg [71:0] capture_channel_min;
    reg [71:0] capture_channel_max;
    reg [71:0] capture_channel_center;
    integer capture_index;
    integer accumulator_index;
    reg [21:0] center_total;
    reg [10:0] center_count;
    reg [10:0] center_target;
    reg [21:0] center_round;
    reg [9:0] history_valid_count;
    reg [9:0] render_valid_count;
    wire [9:0] render_pretrigger_samples = render_trigger_position == 2'd0 ? 10'd58 :
                                           render_trigger_position == 2'd1 ? 10'd144 :
                                           render_trigger_position == 2'd2 ? 10'd288 : 10'd432;
    wire [9:0] render_trigger_x = PLOT_LEFT + render_pretrigger_samples;
    reg [9:0] valid_sample_count;
    reg [11:0] previous_sample;
    reg trigger_active;
    reg trigger_armed;
    reg trigger_pending;
    reg [9:0] posttrigger_remaining;
    reg capture_frozen;
    reg [5:0] frozen_frames;
    reg [12:0] auto_timeout_count;
    reg run_previous;
    reg [11:0] latest_sample;
    reg [11:0] decimation_min;
    reg [11:0] decimation_max;
    reg [2:0] capture_channel;
    reg [5:0] capture_mask;
    reg [3:0] capture_timebase;
    reg [1:0] capture_average, capture_trigger_mode, capture_trigger_position;
    reg [11:0] capture_trigger_level;
    reg capture_single;

    reg [11:0] measure_min_work;
    reg [11:0] measure_max_work;
    reg [9:0] measure_count;
    reg [11:0] measure_min;
    reg [11:0] measure_max;
    reg [21:0] measure_sum_work;
    reg [21:0] measure_final_sum;
    reg measure_commit_pending;
    reg [11:0] measure_average;

    wire [11:0] measured_span = measure_max - measure_min;
    wire [11:0] adaptive_hysteresis = measured_span[11:5] < 8 ? 12'd8 :
                                      {5'd0, measured_span[11:5]};
    wire [11:0] trigger_hysteresis = stabilize_enable ? adaptive_hysteresis : 12'd2;
    wire [11:0] trigger_lower = trigger_level > trigger_hysteresis ?
                                trigger_level - trigger_hysteresis : 12'd0;
    wire [11:0] trigger_upper = trigger_level < 4095-trigger_hysteresis ?
                                trigger_level + trigger_hysteresis : 12'd4095;
    wire rising_trigger = (trigger_mode == 2'd1 || trigger_mode == 2'd3) &&
                          trigger_armed && sample_data >= trigger_upper;
    wire falling_trigger = trigger_mode == 2'd2 && trigger_armed &&
                           sample_data <= trigger_lower;
    wire sample_crossing = rising_trigger || falling_trigger;

    wire frame_tick = pixel_phase && h_count == H_TOTAL-1 && v_count == V_TOTAL-1;
    wire snapshot_refresh = !channel_stable || !triggered_snapshot_ready ||
                            capture_frozen || trigger_mode == 0 || !run_enable;
    wire channel_stable = channel == capture_channel &&
                          channel_mask == capture_mask &&
                          timebase == capture_timebase &&
                          average_mode == capture_average &&
                          trigger_mode == capture_trigger_mode &&
                          trigger_position == capture_trigger_position &&
                          trigger_level == capture_trigger_level &&
                          single_shot == capture_single;
    // Start a fresh column at the first qualified raw edge. Otherwise the
    // decimator's arbitrary phase can move a slow-scale trigger by one column.
    wire trigger_edge = sample_strobe && channel_stable && run_enable &&
                        !capture_frozen && trigger_mode != 0 && !trigger_active &&
                        !trigger_pending && valid_sample_count >= pretrigger_samples &&
                        sample_crossing;
    wire accept_sample = sample_strobe && channel_stable && !capture_frozen &&
                         run_enable && !trigger_edge &&
                         decimation_count == decimation_limit;
    wire [9:0] first_valid_x = 10'd616 - render_valid_count;
    wire trace_column_valid = h_display >= first_valid_x;
    wire previous_column_valid = h_display > first_valid_x;

    wire [71:0] live_column_min, live_column_max;
    genvar live_ch;
    generate for (live_ch=0; live_ch<6; live_ch=live_ch+1) begin: live_extrema
        assign live_column_min[live_ch*12 +: 12] = render_channel == live_ch ?
            snapshot_min_sample : snapshot_channel_min[live_ch*12 +: 12];
        assign live_column_max[live_ch*12 +: 12] = render_channel == live_ch ?
            snapshot_max_sample : snapshot_channel_max[live_ch*12 +: 12];
    end endgenerate
    scope_live phone_window (
        .clk(clk), .reset(reset), .request(live_request), .metadata_request(live_metadata_request),
        .frame_begin(frame_tick), .snapshot_ready(snapshot_refresh),
        .column_write(snapshot_copy_active && snapshot_copy_valid && !frame_tick),
        .column_index(snapshot_copy_index-10'd1), .column_mean(snapshot_channel_traces),
        .column_min(live_column_min), .column_max(live_column_max),
        .column_valid(snapshot_copy_index > PLOT_WIDTH-render_valid_count ?
                      snapshot_channel_valid & render_channel_mask : 6'd0),
        .channel_mask(channel_mask), .focus(channel), .timebase(timebase),
        .scale(vertical_scale), .position(vertical_position), .trigger_mode(trigger_mode),
        .trigger_position(trigger_position), .trigger_level(trigger_level),
        .manual_mode(manual_mode), .grid(grid_enable), .run(run_enable), .single_shot(single_shot),
        .average_mode(average_mode), .stabilize(stabilize_enable),
        .sample_period(sample_period_cycles), .full_scale_mv(full_scale_mv),
        .valid_columns(channel_stable ? history_valid_count : 10'd0),
        .tx_data(live_tx_data), .tx_valid(live_tx_valid), .tx_pop(live_tx_pop)
    );

    always @* begin
        capture_index = 0;
        center_total = 22'd0;
        center_count = 11'd0;
        center_target = 11'd1 << timebase;
        center_round = timebase == 0 ? 22'd0 : (22'd1 << (timebase - 1'b1));
        for (capture_index = 0; capture_index < 6; capture_index = capture_index + 1) begin
            capture_channel_min[capture_index*12 +: 12] =
                channel_seen_work[capture_index] ?
                channel_min_work[capture_index*12 +: 12] :
                channel_samples[capture_index*12 +: 12];
            capture_channel_max[capture_index*12 +: 12] =
                channel_seen_work[capture_index] ?
                channel_max_work[capture_index*12 +: 12] :
                channel_samples[capture_index*12 +: 12];
            // The center line is the arithmetic mean of every ADC reading
            // in this column. Min/max buffers retain short fast excursions.
            center_total = channel_sum_work[capture_index];
            center_count = channel_count_work[capture_index];
            if (capture_index == channel) begin
                center_total = center_total + sample_data;
                center_count = center_count + 1'b1;
            end
            if (center_count == center_target)
                capture_channel_center[capture_index*12 +: 12] =
                    (center_total + center_round) >> timebase;
            else if (capture_index == channel)
                capture_channel_center[capture_index*12 +: 12] = sample_data;
            else
                capture_channel_center[capture_index*12 +: 12] =
                    channel_samples[capture_index*12 +: 12];
        end
    end

    wire [11:0] focus_column_min = decimation_count == 0 ? sample_data :
        (sample_data < decimation_min ? sample_data : decimation_min);
    wire [11:0] focus_column_max = decimation_count == 0 ? sample_data :
        (sample_data > decimation_max ? sample_data : decimation_max);

    wire [27:0] now_mv_product = latest_sample * render_full_scale_mv;
    wire [27:0] min_mv_product = measure_min * render_full_scale_mv;
    wire [27:0] max_mv_product = measure_max * render_full_scale_mv;
    wire [27:0] pp_mv_product = (measure_max - measure_min) * render_full_scale_mv;
    wire [27:0] avg_mv_product = measure_average * render_full_scale_mv;
    wire [27:0] level_mv_product = render_trigger_level * render_full_scale_mv;
    wire signed [16:0] axis_position_offset =
        ($signed({1'b0, render_vertical_position}) - 17'sd50) <<< 5;
    wire signed [16:0] axis_center_raw = 17'sd2048 + axis_position_offset;
    wire signed [16:0] axis_two_div_raw = 17'sd1024 >>> render_vertical_scale;

    function [11:0] clamp_adc;
        input signed [16:0] value;
        begin
            if (value < 0) clamp_adc = 12'd0;
            else if (value > 4095) clamp_adc = 12'd4095;
            else clamp_adc = value[11:0];
        end
    endfunction

    wire [11:0] axis_top_raw = clamp_adc(axis_center_raw + (axis_two_div_raw <<< 1));
    wire [11:0] axis_upper_raw = clamp_adc(axis_center_raw + axis_two_div_raw);
    wire [11:0] axis_mid_raw = clamp_adc(axis_center_raw);
    wire [11:0] axis_lower_raw = clamp_adc(axis_center_raw - axis_two_div_raw);
    wire [11:0] axis_bottom_raw = clamp_adc(axis_center_raw - (axis_two_div_raw <<< 1));
    wire [27:0] axis_top_mv_product = axis_top_raw * render_full_scale_mv;
    wire [27:0] axis_upper_mv_product = axis_upper_raw * render_full_scale_mv;
    wire [27:0] axis_mid_mv_product = axis_mid_raw * render_full_scale_mv;
    wire [27:0] axis_lower_mv_product = axis_lower_raw * render_full_scale_mv;
    wire [27:0] axis_bottom_mv_product = axis_bottom_raw * render_full_scale_mv;
    wire [33:0] decimated_sample_period = {10'd0, sample_period_cycles} << timebase;
    wire [42:0] time_div_scaled = decimated_sample_period * 10'd590;
    wire [35:0] axis_mid_time_us = render_time_div_us * 3'd5;
    wire [35:0] axis_end_time_us = render_time_div_us * 4'd10;

    // Dedicated synchronous read port for the acquisition memories. Keeping
    // the address registered preserves MAX 10 block-RAM inference.
    always @(posedge clk) begin
        snapshot_sample <= sample_memory[snapshot_read_address];
        snapshot_min_sample <= sample_min_memory[snapshot_read_address];
        snapshot_max_sample <= sample_max_memory[snapshot_read_address];
        snapshot_channel_traces <= channel_trace_memory[snapshot_read_address];
        snapshot_channel_min <= channel_min_memory[snapshot_read_address];
        snapshot_channel_max <= channel_max_memory[snapshot_read_address];
        snapshot_channel_valid <= channel_valid_memory[snapshot_read_address];
    end

    function [29:0] bcd_step4;
        input [29:0] value;
        integer d;
        reg [29:0] work;
        begin
            work = value;
            for (d=0; d<4; d=d+1)
                if (work[14+d*4 +: 4] > 4)
                    work[14+d*4 +: 4] = work[14+d*4 +: 4] + 3;
            bcd_step4 = work << 1;
        end
    endfunction

    function [55:0] bcd_step8;
        input [55:0] value;
        integer d;
        reg [55:0] work;
        begin
            work = value;
            for (d=0; d<8; d=d+1)
                if (work[24+d*4 +: 4] > 4)
                    work[24+d*4 +: 4] = work[24+d*4 +: 4] + 3;
            bcd_step8 = work << 1;
        end
    endfunction

    // Decimal formatting runs only once per video frame.  Fourteen small
    // shift/add-3 steps replace large dividers in the live pixel path.
    always @(posedge clk) begin
        if (reset) begin
            display_bcd_count <= 0;
            for(voltage_index=0;voltage_index<6;voltage_index=voltage_index+1) begin
                channel_voltage_shift[voltage_index] <= 0;
                channel_voltage_bcd[voltage_index] <= 0;
            end
            display_adc_bcd <= 0; display_now_bcd <= 0; display_min_bcd <= 0; display_max_bcd <= 0;
            display_pp_bcd <= 0; display_avg_bcd <= 0; display_level_bcd <= 0;
            display_vdiv_bcd <= 0; display_time_bcd <= 0;
            display_axis_mid_time_bcd <= 0; display_axis_end_time_bcd <= 0;
            display_axis_top_bcd <= 0; display_axis_upper_bcd <= 0;
            display_axis_mid_bcd <= 0; display_axis_lower_bcd <= 0;
            display_axis_bottom_bcd <= 0;
            bcd_adc_shift <= 0; bcd_now_shift <= 0; bcd_min_shift <= 0; bcd_max_shift <= 0;
            bcd_pp_shift <= 0; bcd_avg_shift <= 0; bcd_level_shift <= 0;
            bcd_vdiv_shift <= 0; bcd_time_shift <= 0;
            bcd_axis_mid_time_shift <= 0; bcd_axis_end_time_shift <= 0;
            bcd_axis_top_shift <= 0; bcd_axis_upper_shift <= 0;
            bcd_axis_mid_shift <= 0; bcd_axis_lower_shift <= 0;
            bcd_axis_bottom_shift <= 0;
        end else if (display_bcd_count == 0) begin
            if (frame_tick) begin
                for(voltage_index=0;voltage_index<6;voltage_index=voltage_index+1)
                    channel_voltage_shift[voltage_index] <=
                        {16'd0, ((channel_mv_product[voltage_index] + 2048) >> 12)};
                bcd_adc_shift <= {18'd0, latest_sample};
                bcd_now_shift <= {16'd0, ((now_mv_product + 2048) >> 12)};
                bcd_min_shift <= {16'd0, ((min_mv_product + 2048) >> 12)};
                bcd_max_shift <= {16'd0, ((max_mv_product + 2048) >> 12)};
                bcd_pp_shift <= {16'd0, ((pp_mv_product + 2048) >> 12)};
                bcd_avg_shift <= {16'd0, ((avg_mv_product + 2048) >> 12)};
                bcd_level_shift <= {16'd0, ((level_mv_product + 2048) >> 12)};
                bcd_vdiv_shift <= {16'd0, 1'b0, (render_full_scale_mv >> (3 + render_vertical_scale))};
                bcd_axis_top_shift <= {16'd0, ((axis_top_mv_product + 2048) >> 12)};
                bcd_axis_upper_shift <= {16'd0, ((axis_upper_mv_product + 2048) >> 12)};
                bcd_axis_mid_shift <= {16'd0, ((axis_mid_mv_product + 2048) >> 12)};
                bcd_axis_lower_shift <= {16'd0, ((axis_lower_mv_product + 2048) >> 12)};
                bcd_axis_bottom_shift <= {16'd0, ((axis_bottom_mv_product + 2048) >> 12)};
                bcd_time_shift <= {32'd0, render_time_div_us[23:0]};
                bcd_axis_mid_time_shift <= {32'd0, axis_mid_time_us[23:0]};
                bcd_axis_end_time_shift <= {32'd0, axis_end_time_us[23:0]};
                display_bcd_count <= 24;
            end
        end else begin
            if (display_bcd_count > 10) begin
                for(voltage_index=0;voltage_index<6;voltage_index=voltage_index+1)
                    channel_voltage_shift[voltage_index] <= bcd_step4(channel_voltage_shift[voltage_index]);
                bcd_adc_shift <= bcd_step4(bcd_adc_shift);
                bcd_now_shift <= bcd_step4(bcd_now_shift);
                bcd_min_shift <= bcd_step4(bcd_min_shift);
                bcd_max_shift <= bcd_step4(bcd_max_shift);
                bcd_pp_shift <= bcd_step4(bcd_pp_shift);
                bcd_avg_shift <= bcd_step4(bcd_avg_shift);
                bcd_level_shift <= bcd_step4(bcd_level_shift);
                bcd_vdiv_shift <= bcd_step4(bcd_vdiv_shift);
                bcd_axis_top_shift <= bcd_step4(bcd_axis_top_shift);
                bcd_axis_upper_shift <= bcd_step4(bcd_axis_upper_shift);
                bcd_axis_mid_shift <= bcd_step4(bcd_axis_mid_shift);
                bcd_axis_lower_shift <= bcd_step4(bcd_axis_lower_shift);
                bcd_axis_bottom_shift <= bcd_step4(bcd_axis_bottom_shift);
            end
            bcd_time_shift <= bcd_step8(bcd_time_shift);
            bcd_axis_mid_time_shift <= bcd_step8(bcd_axis_mid_time_shift);
            bcd_axis_end_time_shift <= bcd_step8(bcd_axis_end_time_shift);
            display_bcd_count <= display_bcd_count - 1'b1;
            if (display_bcd_count == 11) begin
                for(voltage_index=0;voltage_index<6;voltage_index=voltage_index+1)
                    channel_voltage_bcd[voltage_index] <= bcd_step4(channel_voltage_shift[voltage_index]) >> 14;
                display_adc_bcd <= bcd_step4(bcd_adc_shift) >> 14;
                display_now_bcd <= bcd_step4(bcd_now_shift) >> 14;
                display_min_bcd <= bcd_step4(bcd_min_shift) >> 14;
                display_max_bcd <= bcd_step4(bcd_max_shift) >> 14;
                display_pp_bcd <= bcd_step4(bcd_pp_shift) >> 14;
                display_avg_bcd <= bcd_step4(bcd_avg_shift) >> 14;
                display_level_bcd <= bcd_step4(bcd_level_shift) >> 14;
                display_vdiv_bcd <= bcd_step4(bcd_vdiv_shift) >> 14;
                display_axis_top_bcd <= bcd_step4(bcd_axis_top_shift) >> 14;
                display_axis_upper_bcd <= bcd_step4(bcd_axis_upper_shift) >> 14;
                display_axis_mid_bcd <= bcd_step4(bcd_axis_mid_shift) >> 14;
                display_axis_lower_bcd <= bcd_step4(bcd_axis_lower_shift) >> 14;
                display_axis_bottom_bcd <= bcd_step4(bcd_axis_bottom_shift) >> 14;
            end
            if (display_bcd_count == 1) begin
                display_time_bcd <= bcd_step8(bcd_time_shift) >> 24;
                display_axis_mid_time_bcd <= bcd_step8(bcd_axis_mid_time_shift) >> 24;
                display_axis_end_time_bcd <= bcd_step8(bcd_axis_end_time_shift) >> 24;
            end
        end
    end

    // Acquisition, decimation, triggering, and measurements.
    always @(posedge clk) begin
        if (reset) begin
            write_pointer          <= 10'd0;
            display_start          <= 10'd0;
            decimation_count       <= 10'd0;
            valid_sample_count     <= 10'd0;
            previous_sample        <= 12'd0;
            trigger_active         <= 1'b0;
            capture_was_triggered <= 1'b0;
            trigger_armed          <= 1'b0;
            trigger_pending        <= 1'b0;
            posttrigger_remaining  <= 10'd0;
            capture_frozen         <= 1'b0;
            frozen_frames          <= 6'd0;
            auto_timeout_count     <= 13'd0;
            run_previous           <= 1'b1;
            latest_sample          <= 12'd0;
            decimation_min         <= 12'hfff;
            decimation_max         <= 12'd0;
            measure_min_work       <= 12'hfff;
            measure_max_work       <= 12'd0;
            measure_count          <= 10'd0;
            measure_min            <= 12'd0;
            measure_max            <= 12'd0;
            measure_sum_work       <= 22'd0;
            measure_final_sum      <= 22'd0;
            measure_commit_pending <= 1'b0;
            measure_average        <= 12'd0;
            capture_channel        <= 3'd0;
            capture_mask           <= 6'b000001;
            capture_timebase       <= 4'd0;
            capture_average <= 0; capture_trigger_mode <= 3;
            capture_trigger_position <= 1; capture_trigger_level <= 2048;
            capture_single <= 0;
            channel_min_work       <= 72'd0;
            channel_max_work       <= 72'd0;
            for (accumulator_index = 0; accumulator_index < 6; accumulator_index = accumulator_index + 1) begin
                channel_sum_work[accumulator_index] <= 22'd0;
                channel_count_work[accumulator_index] <= 11'd0;
            end
            channel_seen_work      <= 6'd0;
            channel_seen_since_selection <= 6'd0;
            history_valid_count    <= 10'd0;
        end else begin
            run_previous <= run_enable;
            // Finish the decimal mean one clock after the last column. This
            // keeps the wide 576-point multiply off the ADC write path.
            if (measure_commit_pending) begin
                measure_average <= (measure_final_sum * 9'd455 + 18'd131072) >> 18;
                measure_commit_pending <= 1'b0;
            end

            // A selection or timebase change starts a clean acquisition. No
            // visible window may mix channels or different sample intervals.
            if (!channel_stable) begin
                capture_channel <= channel;
                capture_mask <= channel_mask;
                capture_timebase <= timebase;
                capture_average <= average_mode; capture_trigger_mode <= trigger_mode;
                capture_trigger_position <= trigger_position;
                capture_trigger_level <= trigger_level; capture_single <= single_shot;
                write_pointer <= 10'd0;display_start <= 10'd0;decimation_count <= 10'd0;
                valid_sample_count <= 10'd0;trigger_active <= 1'b0;trigger_armed <= 1'b0;
                capture_was_triggered <= 1'b0;
                trigger_pending <= 1'b0;capture_frozen <= 1'b0;frozen_frames <= 6'd0;
                auto_timeout_count <= 13'd0;
                channel_seen_work <= 6'd0;
                for (accumulator_index = 0; accumulator_index < 6; accumulator_index = accumulator_index + 1) begin
                    channel_sum_work[accumulator_index] <= 22'd0;
                    channel_count_work[accumulator_index] <= 11'd0;
                end
                channel_seen_since_selection <= 6'd0;
                history_valid_count <= 10'd0;
                measure_min_work <= 12'hfff;measure_max_work <= 12'd0;
                measure_sum_work <= 22'd0;measure_count <= 10'd0;
                measure_commit_pending <= 1'b0;
                measure_min <= 12'd0;measure_max <= 12'd0;measure_average <= 12'd0;
            end

            if (!run_enable && run_previous) begin
                capture_frozen <= 1'b1;
                display_start <= write_pointer - PLOT_WIDTH;
            end else if (run_enable && !run_previous) begin
                capture_frozen <= 1'b0;
                trigger_active <= 1'b0;
                trigger_armed <= 1'b0;
                trigger_pending <= 1'b0;
                valid_sample_count <= 10'd0;
                channel_seen_work <= 6'd0;
                for (accumulator_index = 0; accumulator_index < 6; accumulator_index = accumulator_index + 1) begin
                    channel_sum_work[accumulator_index] <= 22'd0;
                    channel_count_work[accumulator_index] <= 11'd0;
                end
                measure_min_work <= 12'hfff;measure_max_work <= 12'd0;
                measure_sum_work <= 22'd0;measure_count <= 10'd0;
                measure_commit_pending <= 1'b0;
                history_valid_count <= 10'd0;
                frozen_frames <= 6'd0;
                auto_timeout_count <= 13'd0;
            end

            // Accumulate the true per-input extrema between focus columns.
            // This retains narrow pulses on comparison traces at slow
            // timebases, just as the focus envelope does.
            if (scan_sample_strobe && channel_stable && run_enable &&
                !capture_frozen &&
                channel_mask[scan_sample_channel]) begin
                channel_seen_since_selection[scan_sample_channel] <= 1'b1;
                if (channel_count_work[scan_sample_channel] < 11'd1024) begin
                    channel_sum_work[scan_sample_channel] <=
                        channel_sum_work[scan_sample_channel] + scan_sample_data;
                    channel_count_work[scan_sample_channel] <=
                        channel_count_work[scan_sample_channel] + 1'b1;
                end
                if (!channel_seen_work[scan_sample_channel]) begin
                    channel_min_work[scan_sample_channel*12 +: 12] <= scan_sample_data;
                    channel_max_work[scan_sample_channel*12 +: 12] <= scan_sample_data;
                    channel_seen_work[scan_sample_channel] <= 1'b1;
                end else begin
                    if (scan_sample_data < channel_min_work[scan_sample_channel*12 +: 12])
                        channel_min_work[scan_sample_channel*12 +: 12] <= scan_sample_data;
                    if (scan_sample_data > channel_max_work[scan_sample_channel*12 +: 12])
                        channel_max_work[scan_sample_channel*12 +: 12] <= scan_sample_data;
                end
            end

            if (sample_strobe && channel_stable && run_enable && !capture_frozen) begin
                previous_sample <= sample_data;
                if (decimation_count == 0) begin
                    decimation_min <= sample_data;
                    decimation_max <= sample_data;
                end else begin
                    if (sample_data < decimation_min) decimation_min <= sample_data;
                    if (sample_data > decimation_max) decimation_max <= sample_data;
                end
                if (trigger_edge) begin
                    trigger_pending <= 1'b1;
                    trigger_armed <= 1'b0;
                    decimation_count <= 10'd0;
                    decimation_min <= 12'hfff;
                    decimation_max <= 12'd0;
                    channel_seen_work <= 6'd0;
                    for (accumulator_index = 0; accumulator_index < 6; accumulator_index = accumulator_index + 1) begin
                        channel_sum_work[accumulator_index] <= 22'd0;
                        channel_count_work[accumulator_index] <= 11'd0;
                    end
                end else begin
                    if (!trigger_pending && !trigger_active) begin
                        if ((trigger_mode == 2'd1 || trigger_mode == 2'd3) && sample_data <= trigger_lower)
                            trigger_armed <= 1'b1;
                        else if (trigger_mode == 2'd2 && sample_data >= trigger_upper)
                            trigger_armed <= 1'b1;
                    end
                    if (decimation_count == decimation_limit)
                        decimation_count <= 10'd0;
                    else
                        decimation_count <= decimation_count + 1'b1;
                end
            end

            if (accept_sample) begin
                sample_memory[write_pointer] <= capture_channel_center[channel*12 +: 12];
                channel_trace_memory[write_pointer] <= capture_channel_center;
                channel_min_memory[write_pointer] <= capture_channel_min;
                channel_max_memory[write_pointer] <= capture_channel_max;
                channel_valid_memory[write_pointer] <=
                    channel_seen_since_selection | (6'b000001 << channel);
                channel_seen_work <= 6'd0;
                for (accumulator_index = 0; accumulator_index < 6; accumulator_index = accumulator_index + 1) begin
                    channel_sum_work[accumulator_index] <= 22'd0;
                    channel_count_work[accumulator_index] <= 11'd0;
                end
                if (history_valid_count < PLOT_WIDTH)
                    history_valid_count <= history_valid_count + 1'b1;
                sample_min_memory[write_pointer] <= focus_column_min;
                sample_max_memory[write_pointer] <= focus_column_max;
                write_pointer <= write_pointer + 1'b1;
                latest_sample <= sample_data;
                display_start <= write_pointer - (PLOT_WIDTH-1);

                if (valid_sample_count < PLOT_WIDTH)
                    valid_sample_count <= valid_sample_count + 1'b1;

                if (focus_column_min < measure_min_work) measure_min_work <= focus_column_min;
                if (focus_column_max > measure_max_work) measure_max_work <= focus_column_max;
                if (measure_count == PLOT_WIDTH-1) begin
                    measure_min <= focus_column_min < measure_min_work ? focus_column_min : measure_min_work;
                    measure_max <= focus_column_max > measure_max_work ? focus_column_max : measure_max_work;
                    measure_min_work <= 12'hfff;
                    measure_max_work <= 12'd0;
                    // 455/2^18 approximates 1/576 to better than one ADC count.
                    measure_final_sum <= measure_sum_work + capture_channel_center[channel*12 +: 12];
                    measure_commit_pending <= 1'b1;
                    measure_sum_work <= 22'd0;
                    measure_count <= 10'd0;
                end else begin
                    measure_sum_work <= measure_sum_work + capture_channel_center[channel*12 +: 12];
                    measure_count <= measure_count + 1'b1;
                end

                if (trigger_mode != 0 && !trigger_active &&
                    valid_sample_count >= pretrigger_samples &&
                    trigger_pending) begin
                    trigger_active <= 1'b1;
                    capture_was_triggered <= 1'b1;
                    trigger_armed <= 1'b0;
                    trigger_pending <= 1'b0;
                    auto_timeout_count <= 13'd0;
                    posttrigger_remaining <= PLOT_WIDTH - pretrigger_samples - 1'b1;
                end else if (trigger_active) begin
                    if (posttrigger_remaining <= 1) begin
                        capture_frozen <= 1'b1;
                        trigger_active <= 1'b0;
                        display_start <= write_pointer - (PLOT_WIDTH-1);
                        frozen_frames <= 6'd0;
                    end else begin
                        posttrigger_remaining <= posttrigger_remaining - 1'b1;
                    end
                end else if (trigger_mode == 2'd3 && valid_sample_count >= PLOT_WIDTH) begin
                    // Give slow signals four complete windows to reach the
                    // selected edge before AUTO falls back to an unlocked view.
                    if (auto_timeout_count >= PLOT_WIDTH*4-1) begin
                        capture_was_triggered <= 1'b0;
                        capture_frozen <= 1'b1;
                        display_start <= write_pointer - (PLOT_WIDTH-1);
                        frozen_frames <= 6'd0;
                        auto_timeout_count <= 13'd0;
                    end else begin
                        auto_timeout_count <= auto_timeout_count + 1'b1;
                    end
                end else if (trigger_mode != 2'd3) begin
                    auto_timeout_count <= 13'd0;
                end
            end

            // LIVE mode displays for one frame, minimizing latency. Optional
            // stabilization holds six frames (~100 ms) to suppress jitter.
            if (frame_tick && channel_stable && capture_frozen && run_enable && !single_shot) begin
                if ((!stabilize_enable && frozen_frames == 0) ||
                    (stabilize_enable && frozen_frames == 6'd5)) begin
                    capture_frozen <= 1'b0;
                    valid_sample_count <= 10'd0;
                    decimation_count <= 10'd0;
                    channel_seen_work <= 6'd0;
                    for (accumulator_index = 0; accumulator_index < 6; accumulator_index = accumulator_index + 1) begin
                        channel_sum_work[accumulator_index] <= 22'd0;
                        channel_count_work[accumulator_index] <= 11'd0;
                    end
                    trigger_armed <= 1'b0;
                    trigger_pending <= 1'b0;
                    frozen_frames <= 6'd0;
                end else begin
                    frozen_frames <= frozen_frames + 1'b1;
                end
            end
        end
    end

    // Pixel counters and synchronous waveform read port.
    always @(posedge clk) begin
        if (reset) begin
            pixel_phase <= 1'b0;
            h_count <= 10'd0;
            v_count <= 10'd0;
            h_pipe <= 10'd0;
            v_pipe <= 10'd0;
            h_render <= 10'd0;
            v_render <= 10'd0;
            h_display <= 10'd0;
            v_display <= 10'd0;
            read_address <= 10'd0;
            read_sample <= 12'd0;
            read_min_sample <= 12'd0;
            read_max_sample <= 12'd0;
            read_channel_traces <= 72'd0;
            read_channel_min <= 72'd0;
            read_channel_max <= 72'd0;
            read_channel_valid <= 6'd0;
            render_channel <= 3'd0;
            render_channel_mask <= 6'b000001;
            render_seen_mask <= 6'd0;
            render_valid_count <= 10'd0;
            render_channel_samples <= 72'd0;
            render_timebase <= 3'd0;
            render_vertical_scale <= 2'd0;
            render_vertical_position <= 7'd50;
            render_trigger_mode <= 2'd3;
            render_trigger_level <= 12'd2048;
            render_grid_enable <= 1'b1;
            render_run_enable <= 1'b1;
            render_manual_mode <= 1'b0;
            render_trigger_position <= 2'd1;
            render_single_shot <= 1'b0;
            render_average_mode <= 2'd0;
            render_stabilize_enable <= 1'b0;
            render_full_scale_mv <= 16'd5000;
            render_time_div_us <= 32'd2920;
            snapshot_copy_active <= 1'b0;
            snapshot_copy_valid <= 1'b0;
            frame_snapshot_ready <= 1'b0;
            triggered_snapshot_ready <= 1'b0;
            snapshot_start <= 10'd0;
            snapshot_read_address <= 10'd0;
            snapshot_copy_index <= 10'd0;
        end else begin
            pixel_phase <= ~pixel_phase;
            if (!channel_stable || trigger_mode == 0) triggered_snapshot_ready <= 1'b0;
            else if (frame_tick && capture_frozen && history_valid_count == PLOT_WIDTH)
                triggered_snapshot_ready <= capture_was_triggered;

            // Copy the 576-point view during vertical blanking. Acquisition
            // continues during the copy: the 1024-point ring leaves 448 spare
            // addresses, and ADC strobes are at least two system clocks apart,
            // so the writer cannot overtake the copy's one-point-per-clock read.
            if (frame_tick) begin
                // Keep all visible settings coherent for an entire frame. A
                // phone update can otherwise move the trace or graticule part
                // way down the screen and produce a one-frame horizontal tear.
                render_channel <= channel;
                render_channel_mask <= channel_mask;
                if (snapshot_refresh) begin
                    render_seen_mask <= channel_stable ? channel_seen_since_selection : 6'd0;
                    render_valid_count <= channel_stable ? history_valid_count : 10'd0;
                end
                render_channel_samples <= channel_samples;
                render_timebase <= timebase;
                render_vertical_scale <= vertical_scale;
                render_vertical_position <= vertical_position;
                render_trigger_mode <= trigger_mode;
                render_trigger_level <= trigger_level;
                render_grid_enable <= grid_enable;
                render_run_enable <= run_enable;
                render_manual_mode <= manual_mode;
                render_trigger_position <= trigger_position;
                render_single_shot <= single_shot;
                render_average_mode <= average_mode;
                render_stabilize_enable <= stabilize_enable;
                render_full_scale_mv <= full_scale_mv;
                // The plot has ten horizontal divisions. sample_period_cycles
                // is measured against the 50 MHz system clock. 590/512 is the
                // rounded fixed-point form of 576/500.
                render_time_div_us <= (time_div_scaled + 9'd256) >> 9;
                // Keep the last complete triggered view while the next long
                // acquisition fills. Free-run continues refreshing each frame.
                if (snapshot_refresh) begin
                    snapshot_start <= display_start;
                    snapshot_read_address <= display_start;
                    snapshot_copy_index <= 10'd0;
                    snapshot_copy_active <= 1'b1;
                    snapshot_copy_valid <= 1'b0;
                    frame_snapshot_ready <= 1'b0;
                end
            end else if (snapshot_copy_active) begin
                if (snapshot_copy_valid) begin
                    frame_sample_memory[snapshot_copy_index-1'b1] <= snapshot_sample;
                    frame_min_memory[snapshot_copy_index-1'b1] <= snapshot_min_sample;
                    frame_max_memory[snapshot_copy_index-1'b1] <= snapshot_max_sample;
                    frame_channel_trace_memory[snapshot_copy_index-1'b1] <= snapshot_channel_traces;
                    frame_channel_min_memory[snapshot_copy_index-1'b1] <= snapshot_channel_min;
                    frame_channel_max_memory[snapshot_copy_index-1'b1] <= snapshot_channel_max;
                    frame_channel_valid_memory[snapshot_copy_index-1'b1] <= snapshot_channel_valid;
                end
                if (snapshot_copy_index < PLOT_WIDTH) begin
                    snapshot_read_address <= snapshot_start + snapshot_copy_index + 1'b1;
                    snapshot_copy_index <= snapshot_copy_index + 1'b1;
                    snapshot_copy_valid <= 1'b1;
                end else begin
                    snapshot_copy_active <= 1'b0;
                    snapshot_copy_valid <= 1'b0;
                    frame_snapshot_ready <= 1'b1;
                end
            end

            if (pixel_phase) begin
                h_pipe <= h_count;
                v_pipe <= v_count;
                h_render <= h_pipe;
                v_render <= v_pipe;
                h_display <= h_render;
                v_display <= v_render;
                if (h_count >= PLOT_LEFT && h_count <= PLOT_RIGHT)
                    read_address <= h_count - PLOT_LEFT;
                read_sample <= frame_sample_memory[read_address];
                read_min_sample <= frame_min_memory[read_address];
                read_max_sample <= frame_max_memory[read_address];
                read_channel_traces <= frame_channel_trace_memory[read_address];
                read_channel_min <= frame_channel_min_memory[read_address];
                read_channel_max <= frame_channel_max_memory[read_address];
                read_channel_valid <= frame_channel_valid_memory[read_address];

                if (h_count == H_TOTAL-1) begin
                    h_count <= 10'd0;
                    if (v_count == V_TOTAL-1) v_count <= 10'd0;
                    else v_count <= v_count + 1'b1;
                end else begin
                    h_count <= h_count + 1'b1;
                end
            end
        end
    end

    function [9:0] waveform_y;
        input [11:0] value;
        integer centered;
        integer scaled;
        integer result;
        begin
            centered = $signed({1'b0, value}) - 2048 - (($signed({1'b0, render_vertical_position}) - 50) * 32);
            scaled = centered * (1 << render_vertical_scale);
            result = 210 - ((scaled * 336) / 4096);
            if (result < PLOT_TOP) waveform_y = PLOT_TOP;
            else if (result > PLOT_BOTTOM) waveform_y = PLOT_BOTTOM;
            else waveform_y = result[9:0];
        end
    endfunction

    function [4:0] glyph;
        input [7:0] ch;
        input [2:0] row;
        begin
            glyph = 5'b00000;
            case (ch)
                "0": case(row) 0:glyph=5'b01110;1:glyph=5'b10011;2:glyph=5'b10101;3:glyph=5'b10101;4:glyph=5'b11001;5:glyph=5'b10001;6:glyph=5'b01110;endcase
                "1": case(row) 0:glyph=5'b00100;1:glyph=5'b01100;2:glyph=5'b00100;3:glyph=5'b00100;4:glyph=5'b00100;5:glyph=5'b00100;6:glyph=5'b01110;endcase
                "2": case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b00001;3:glyph=5'b00010;4:glyph=5'b00100;5:glyph=5'b01000;6:glyph=5'b11111;endcase
                "3": case(row) 0:glyph=5'b11110;1:glyph=5'b00001;2:glyph=5'b00001;3:glyph=5'b01110;4:glyph=5'b00001;5:glyph=5'b00001;6:glyph=5'b11110;endcase
                "4": case(row) 0:glyph=5'b00010;1:glyph=5'b00110;2:glyph=5'b01010;3:glyph=5'b10010;4:glyph=5'b11111;5:glyph=5'b00010;6:glyph=5'b00010;endcase
                "5": case(row) 0:glyph=5'b11111;1:glyph=5'b10000;2:glyph=5'b11110;3:glyph=5'b00001;4:glyph=5'b00001;5:glyph=5'b10001;6:glyph=5'b01110;endcase
                "6": case(row) 0:glyph=5'b00110;1:glyph=5'b01000;2:glyph=5'b10000;3:glyph=5'b11110;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b01110;endcase
                "7": case(row) 0:glyph=5'b11111;1:glyph=5'b00001;2:glyph=5'b00010;3:glyph=5'b00100;4:glyph=5'b01000;5:glyph=5'b01000;6:glyph=5'b01000;endcase
                "8": case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b01110;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b01110;endcase
                "9": case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b01111;4:glyph=5'b00001;5:glyph=5'b00010;6:glyph=5'b11100;endcase
                "A": case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b11111;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b10001;endcase
                "B": case(row) 0:glyph=5'b11110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b11110;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b11110;endcase
                "C": case(row) 0:glyph=5'b01111;1:glyph=5'b10000;2:glyph=5'b10000;3:glyph=5'b10000;4:glyph=5'b10000;5:glyph=5'b10000;6:glyph=5'b01111;endcase
                "D": case(row) 0:glyph=5'b11110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b10001;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b11110;endcase
                "E": case(row) 0:glyph=5'b11111;1:glyph=5'b10000;2:glyph=5'b10000;3:glyph=5'b11110;4:glyph=5'b10000;5:glyph=5'b10000;6:glyph=5'b11111;endcase
                "F": case(row) 0:glyph=5'b11111;1:glyph=5'b10000;2:glyph=5'b10000;3:glyph=5'b11110;4:glyph=5'b10000;5:glyph=5'b10000;6:glyph=5'b10000;endcase
                "G": case(row) 0:glyph=5'b01111;1:glyph=5'b10000;2:glyph=5'b10000;3:glyph=5'b10111;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b01111;endcase
                "H": case(row) 0:glyph=5'b10001;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b11111;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b10001;endcase
                "I": case(row) 0:glyph=5'b01110;1:glyph=5'b00100;2:glyph=5'b00100;3:glyph=5'b00100;4:glyph=5'b00100;5:glyph=5'b00100;6:glyph=5'b01110;endcase
                "L": case(row) 0:glyph=5'b10000;1:glyph=5'b10000;2:glyph=5'b10000;3:glyph=5'b10000;4:glyph=5'b10000;5:glyph=5'b10000;6:glyph=5'b11111;endcase
                "M": case(row) 0:glyph=5'b10001;1:glyph=5'b11011;2:glyph=5'b10101;3:glyph=5'b10101;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b10001;endcase
                "N": case(row) 0:glyph=5'b10001;1:glyph=5'b11001;2:glyph=5'b10101;3:glyph=5'b10011;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b10001;endcase
                "O": case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b10001;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b01110;endcase
                "P": case(row) 0:glyph=5'b11110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b11110;4:glyph=5'b10000;5:glyph=5'b10000;6:glyph=5'b10000;endcase
                "Q": case(row) 0:glyph=5'b01110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b10001;4:glyph=5'b10101;5:glyph=5'b10010;6:glyph=5'b01101;endcase
                "R": case(row) 0:glyph=5'b11110;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b11110;4:glyph=5'b10100;5:glyph=5'b10010;6:glyph=5'b10001;endcase
                "S": case(row) 0:glyph=5'b01111;1:glyph=5'b10000;2:glyph=5'b10000;3:glyph=5'b01110;4:glyph=5'b00001;5:glyph=5'b00001;6:glyph=5'b11110;endcase
                "T": case(row) 0:glyph=5'b11111;1:glyph=5'b00100;2:glyph=5'b00100;3:glyph=5'b00100;4:glyph=5'b00100;5:glyph=5'b00100;6:glyph=5'b00100;endcase
                "U": case(row) 0:glyph=5'b10001;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b10001;4:glyph=5'b10001;5:glyph=5'b10001;6:glyph=5'b01110;endcase
                "V": case(row) 0:glyph=5'b10001;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b10001;4:glyph=5'b10001;5:glyph=5'b01010;6:glyph=5'b00100;endcase
                "W": case(row) 0:glyph=5'b10001;1:glyph=5'b10001;2:glyph=5'b10001;3:glyph=5'b10101;4:glyph=5'b10101;5:glyph=5'b11011;6:glyph=5'b10001;endcase
                "X": case(row) 0:glyph=5'b10001;1:glyph=5'b10001;2:glyph=5'b01010;3:glyph=5'b00100;4:glyph=5'b01010;5:glyph=5'b10001;6:glyph=5'b10001;endcase
                "Z": case(row) 0:glyph=5'b11111;1:glyph=5'b00001;2:glyph=5'b00010;3:glyph=5'b00100;4:glyph=5'b01000;5:glyph=5'b10000;6:glyph=5'b11111;endcase
                "-": if(row==3) glyph=5'b11111;
                ".": if(row==6) glyph=5'b00100;
                ":": if(row==2 || row==4) glyph=5'b00100;
                ">": case(row) 1:glyph=5'b10000;2:glyph=5'b01000;3:glyph=5'b00100;4:glyph=5'b01000;5:glyph=5'b10000;endcase
                "/": case(row) 0:glyph=5'b00001;1:glyph=5'b00010;2:glyph=5'b00010;3:glyph=5'b00100;4:glyph=5'b01000;5:glyph=5'b01000;6:glyph=5'b10000;endcase
                "%": case(row) 0:glyph=5'b11001;1:glyph=5'b11010;2:glyph=5'b00100;3:glyph=5'b00100;4:glyph=5'b01011;5:glyph=5'b10011;6:glyph=5'b00000;endcase
                default: glyph=5'b00000;
            endcase
        end
    endfunction

    function [7:0] hex_digit;
        input [3:0] value;
        begin
            if (value < 10) hex_digit = "0" + value;
            else hex_digit = "A" + (value - 10);
        end
    endfunction

    function [7:0] voltage_tick_character;
        input [15:0] bcd;
        input [2:0] position;
        begin
            case(position)
                0: voltage_tick_character = hex_digit(bcd[15:12]);
                1: voltage_tick_character = ".";
                2: voltage_tick_character = hex_digit(bcd[11:8]);
                3: voltage_tick_character = hex_digit(bcd[7:4]);
                4: voltage_tick_character = "V";
                default: voltage_tick_character = " ";
            endcase
        end
    endfunction

    function [7:0] voltage_readout_character;
        input [15:0] bcd;
        input [2:0] position;
        begin
            case(position)
                0: voltage_readout_character = hex_digit(bcd[15:12]);
                1: voltage_readout_character = ".";
                2: voltage_readout_character = hex_digit(bcd[11:8]);
                3: voltage_readout_character = hex_digit(bcd[7:4]);
                4: voltage_readout_character = hex_digit(bcd[3:0]);
                5: voltage_readout_character = "V";
                default: voltage_readout_character = " ";
            endcase
        end
    endfunction

    function [7:0] time_axis_character;
        input [31:0] microseconds;
        input [31:0] bcd;
        input [3:0] position;
        begin
            time_axis_character = " ";
            if (microseconds < 1000) begin
                if(position==0 && microseconds>=100)time_axis_character=hex_digit(bcd[11:8]);
                else if(position==1 && microseconds>=10)time_axis_character=hex_digit(bcd[7:4]);
                else if(position==2)time_axis_character=hex_digit(bcd[3:0]);
                else if(position==3)time_axis_character="U";else if(position==4)time_axis_character="S";
            end else if (microseconds < 10000) begin
                if(position==0)time_axis_character=hex_digit(bcd[15:12]);else if(position==1)time_axis_character=".";
                else if(position==2)time_axis_character=hex_digit(bcd[11:8]);else if(position==3)time_axis_character=hex_digit(bcd[7:4]);
                else if(position==4)time_axis_character="M";else if(position==5)time_axis_character="S";
            end else if (microseconds < 100000) begin
                if(position==0)time_axis_character=hex_digit(bcd[19:16]);else if(position==1)time_axis_character=hex_digit(bcd[15:12]);
                else if(position==2)time_axis_character=".";else if(position==3)time_axis_character=hex_digit(bcd[11:8]);
                else if(position==4)time_axis_character="M";else if(position==5)time_axis_character="S";
            end else if (microseconds < 1000000) begin
                if(position==0)time_axis_character=hex_digit(bcd[23:20]);else if(position==1)time_axis_character=hex_digit(bcd[19:16]);
                else if(position==2)time_axis_character=hex_digit(bcd[15:12]);else if(position==3)time_axis_character="M";
                else if(position==4)time_axis_character="S";
            end else if (microseconds < 10000000) begin
                if(position==0)time_axis_character=hex_digit(bcd[27:24]);else if(position==1)time_axis_character=".";
                else if(position==2)time_axis_character=hex_digit(bcd[23:20]);else if(position==3)time_axis_character=hex_digit(bcd[19:16]);
                else if(position==4)time_axis_character="S";
            end else begin
                if(position==0)time_axis_character=hex_digit(bcd[31:28]);else if(position==1)time_axis_character=hex_digit(bcd[27:24]);
                else if(position==2)time_axis_character=".";else if(position==3)time_axis_character=hex_digit(bcd[23:20]);
                else if(position==4)time_axis_character="S";
            end
        end
    endfunction

    // Text grid character generator. Essential settings and measurements live
    // in a compact bottom strip, leaving nearly the full VGA width for signal.
    function [7:0] screen_character;
        input [6:0] column;
        input [5:0] line;
        integer p;
        begin
            screen_character = " ";
            p = 0;
            if (line == 50) begin
                if(column==5)screen_character="C";else if(column==6)screen_character="H";else if(column==7)screen_character="0"+render_channel;
                else if(column>=10 && column<17) begin
                    p=column-10;
                    if(render_manual_mode)case(p)0:screen_character="M";1:screen_character="A";2:screen_character="N";3:screen_character="U";4:screen_character="A";5:screen_character="L";endcase
                    else if(!render_run_enable)case(p)0:screen_character="H";1:screen_character="O";2:screen_character="L";3:screen_character="D";endcase
                    else if(render_single_shot && capture_frozen)case(p)0:screen_character="S";1:screen_character="I";2:screen_character="N";3:screen_character="G";4:screen_character="L";5:screen_character="E";endcase
                    else if(capture_frozen)case(p)0:screen_character="C";1:screen_character="A";2:screen_character="P";3:screen_character="T";endcase
                    else case(p)0:screen_character="A";1:screen_character="R";2:screen_character="M";3:screen_character="E";4:screen_character="D";endcase
                end else if(column>=19 && column<32) begin
                    p=column-19;
                    if(p==0)screen_character="T";else if(p==1)screen_character="/";else if(p==2)screen_character="D";
                    else if(p>=4)screen_character=time_axis_character(render_time_div_us,display_time_bcd,p-4);
                end else if(column>=33 && column<46) begin
                    p=column-33;
                    if(p==0)screen_character="V";else if(p==1)screen_character="/";else if(p==2)screen_character="D";
                    else if(p>=4)screen_character=voltage_readout_character(display_vdiv_bcd,p-4);
                end else if(column>=47 && column<59) begin
                    p=column-47;
                    if(p==0)screen_character="T";else if(p==1)screen_character="R";else if(p==2)screen_character="I";else if(p==3)screen_character="G";
                    else if(p>=5 && render_trigger_mode==0)case(p-5)0:screen_character="F";1:screen_character="R";2:screen_character="E";3:screen_character="E";endcase
                    else if(p>=5 && render_trigger_mode==1)case(p-5)0:screen_character="R";1:screen_character="I";2:screen_character="S";3:screen_character="E";endcase
                    else if(p>=5 && render_trigger_mode==2)case(p-5)0:screen_character="F";1:screen_character="A";2:screen_character="L";3:screen_character="L";endcase
                    else if(p>=5)case(p-5)0:screen_character="A";1:screen_character="U";2:screen_character="T";3:screen_character="O";endcase
                end else if(column>=60 && column<75) begin
                    p=column-60;
                    if(p==0)screen_character="L";else if(p==1)screen_character="V";else if(p==2)screen_character="L";
                    else if(p>=4)screen_character=voltage_readout_character(display_level_bcd,p-4);
                end
            end else if (column < 5 && line == 5) begin
                screen_character = voltage_tick_character(display_axis_top_bcd, column[2:0]);
            end else if (column < 5 && line == 15) begin
                screen_character = voltage_tick_character(display_axis_upper_bcd, column[2:0]);
            end else if (column < 5 && line == 26) begin
                screen_character = voltage_tick_character(display_axis_mid_bcd, column[2:0]);
            end else if (column < 5 && line == 36) begin
                screen_character = voltage_tick_character(display_axis_lower_bcd, column[2:0]);
            end else if (column < 5 && line == 47) begin
                screen_character = voltage_tick_character(display_axis_bottom_bcd, column[2:0]);
            end else if (line == 48 && column == 5) begin
                screen_character = "0";
            end else if (line == 48 && column >= 38 && column < 45) begin
                screen_character = time_axis_character(axis_mid_time_us[31:0],
                    display_axis_mid_time_bcd, column - 38);
            end else if (line == 48 && column >= 70 && column < 78) begin
                screen_character = time_axis_character(axis_end_time_us[31:0],
                    display_axis_end_time_bcd, column - 70);
            end
        end
    endfunction

    reg [9:0] previous_wave_y;
    reg [9:0] previous_channel_y [0:5];
    reg [7:0] character;
    reg [4:0] glyph_bits;
    reg [9:0] current_wave_y;
    reg [9:0] current_channel_y [0:5];
    reg [9:0] current_channel_min_y [0:5];
    reg [9:0] current_channel_max_y [0:5];
    reg [5:0] current_channel_valid;
    reg [5:0] previous_channel_valid;
    reg [9:0] current_min_y;
    reg [9:0] current_max_y;
    reg [9:0] trigger_wave_y;
    reg [3:0] red_next, green_next, blue_next;
    reg text_pixel;
    reg status_rule_pixel;
    reg major_grid, minor_grid, border_pixel, axis_tick_pixel, trigger_pixel, trigger_position_pixel, envelope_pixel, wave_pixel;
    reg secondary_wave_pixel;
    reg secondary_envelope_pixel;
    reg [11:0] secondary_color;
    reg [11:0] secondary_envelope_color;
    reg [2:0] legend_channel;
    integer trace_index;
    integer pipeline_index;
    integer char_x, char_y;
    reg [6:0] header_x, metric_x;
    reg [2:0] metric_index;
    reg [15:0] metric_bcd;
    reg header_text;

    function [11:0] trace_color;
        input [2:0] selected;
        begin
            case (selected)
                3'd0: trace_color = 12'h3ff;
                3'd1: trace_color = 12'hfd4;
                3'd2: trace_color = 12'h6f3;
                3'd3: trace_color = 12'hf5a;
                3'd4: trace_color = 12'ha8f;
                default: trace_color = 12'hf82;
            endcase
        end
    endfunction

    function [11:0] dim_trace_color;
        input [2:0] selected;
        begin
            case (selected)
                3'd0: dim_trace_color = 12'h177;
                3'd1: dim_trace_color = 12'h762;
                3'd2: dim_trace_color = 12'h371;
                3'd3: dim_trace_color = 12'h725;
                3'd4: dim_trace_color = 12'h547;
                default: dim_trace_color = 12'h741;
            endcase
        end
    endfunction

    always @* begin
        red_next = 4'h0; green_next = 4'h1; blue_next = 4'h2;
        text_pixel = 1'b0; status_rule_pixel = 1'b0; major_grid = 1'b0; minor_grid = 1'b0;
        border_pixel = 1'b0; axis_tick_pixel = 1'b0; trigger_pixel = 1'b0; trigger_position_pixel = 1'b0; envelope_pixel = 1'b0; wave_pixel = 1'b0;
        secondary_wave_pixel = 1'b0;
        secondary_envelope_pixel = 1'b0;
        secondary_color = 12'h000;
        secondary_envelope_color = 12'h000;
        legend_channel = 3'd0;
        trace_index = 0;
        char_x = h_display[2:0];
        char_y = v_display[2:0];
        character = screen_character(h_display[9:3], v_display[9:3]);
        header_text = 1'b0; header_x = 0; metric_x = 0; metric_index = 0; metric_bcd = 0;
        if (h_display >= 8 && h_display < 624 && v_display < 38) begin
            if(h_display<112)begin legend_channel=0;header_x=h_display-8;end
            else if(h_display<216)begin legend_channel=1;header_x=h_display-112;end
            else if(h_display<320)begin legend_channel=2;header_x=h_display-216;end
            else if(h_display<424)begin legend_channel=3;header_x=h_display-320;end
            else if(h_display<528)begin legend_channel=4;header_x=h_display-424;end
            else begin legend_channel=5;header_x=h_display-528;end
            character = " ";
            char_x = header_x[3:1];
            char_y = 7;
            if(v_display>=2 && v_display<16) begin
                char_y = (v_display-2) >> 1;
                case(header_x[6:4])
                    0: character = render_channel==legend_channel ? ">" : " ";
                    1: character = "C"; 2: character = "H";
                    3: character = "0" + legend_channel;
                    default: character = " ";
                endcase
            end else if(v_display>=22 && v_display<36) begin
                char_y = (v_display-22) >> 1;
                if(!render_channel_mask[legend_channel]) begin
                    if(header_x[6:4]<4)character="-";
                end else case(header_x[6:4])
                    0:character=hex_digit(channel_voltage_bcd[legend_channel][15:12]);
                    1:character=".";
                    2:character=hex_digit(channel_voltage_bcd[legend_channel][11:8]);
                    3:character=hex_digit(channel_voltage_bcd[legend_channel][7:4]);
                    5:character="V";
                    default:character=" ";
                endcase
            end
            header_text = header_x < 96;
            if(!header_text)character=" ";
        end else if(h_display>=40 && h_display<600 && v_display>=424 && v_display<456) begin
            if(h_display<152)begin metric_index=0;metric_x=h_display-40;metric_bcd=display_now_bcd;end
            else if(h_display<264)begin metric_index=1;metric_x=h_display-152;metric_bcd=display_min_bcd;end
            else if(h_display<376)begin metric_index=2;metric_x=h_display-264;metric_bcd=display_max_bcd;end
            else if(h_display<488)begin metric_index=3;metric_x=h_display-376;metric_bcd=display_pp_bcd;end
            else begin metric_index=4;metric_x=h_display-488;metric_bcd=display_avg_bcd;end
            character=" ";char_y=7;
            if(v_display<431) begin
                char_x=metric_x[2:0];char_y=v_display-424;
                case(metric_index)
                    0:case(metric_x[6:3])0:character="N";1:character="O";2:character="W";default:character=" ";endcase
                    1:case(metric_x[6:3])0:character="M";1:character="I";2:character="N";default:character=" ";endcase
                    2:case(metric_x[6:3])0:character="M";1:character="A";2:character="X";default:character=" ";endcase
                    3:case(metric_x[6:3])0:character="P";1:character="-";2:character="P";default:character=" ";endcase
                    4:case(metric_x[6:3])0:character="A";1:character="V";2:character="G";default:character=" ";endcase
                    default:character=" ";
                endcase
            end else if(v_display>=442) begin
                char_x=metric_x[3:1];char_y=(v_display-442)>>1;
                case(metric_x[6:4])
                    0:character=hex_digit(metric_bcd[15:12]);1:character=".";
                    2:character=hex_digit(metric_bcd[11:8]);3:character=hex_digit(metric_bcd[7:4]);
                    5:character="V";default:character=" ";
                endcase
            end
        end
        glyph_bits = glyph(character, char_y[2:0]);
        if (char_x >= 1 && char_x <= 5 && char_y < 7)
            text_pixel = glyph_bits[5-char_x];

        status_rule_pixel = v_display >= 396 && h_display >= 32 && h_display <= 623 &&
            (v_display == 396 || v_display == 419 || v_display == 467 ||
             (v_display < 419 && (h_display == 72 || h_display == 144 ||
              h_display == 256 || h_display == 368 || h_display == 472)) ||
             (v_display > 419 && v_display < 467 && (h_display == 144 ||
              h_display == 256 || h_display == 368 || h_display == 480)));

        if (h_display >= PLOT_LEFT && h_display <= PLOT_RIGHT &&
            v_display >= PLOT_TOP && v_display <= PLOT_BOTTOM) begin
            red_next = 4'h0; green_next = 4'h1; blue_next = 4'h1;
            border_pixel = h_display == PLOT_LEFT || h_display == PLOT_RIGHT ||
                           v_display == PLOT_TOP || v_display == PLOT_BOTTOM;
            // Ten horizontal and eight vertical divisions, matching the scale
            // calculations and the browser graticule.
            major_grid = render_grid_enable && (h_display==40 || h_display==98 || h_display==155 ||
                         h_display==213 || h_display==270 || h_display==328 || h_display==385 ||
                         h_display==443 || h_display==500 || h_display==558 || h_display==615 ||
                         v_display==42 || v_display==84 || v_display==126 || v_display==168 ||
                         v_display==210 || v_display==252 || v_display==294 || v_display==336 ||
                         v_display==377);
            minor_grid = render_grid_enable && (h_display==69 || h_display==126 || h_display==184 ||
                         h_display==241 || h_display==299 || h_display==356 || h_display==414 ||
                         h_display==471 || h_display==529 || h_display==586 || v_display==63 ||
                         v_display==105 || v_display==147 || v_display==189 || v_display==231 ||
                         v_display==273 || v_display==315 || v_display==357);
            trigger_pixel = render_trigger_mode != 0 &&
                            (v_display == trigger_wave_y) && h_display[2:0] < 4;
            trigger_position_pixel = render_trigger_mode != 0 &&
                                     h_display == render_trigger_x && v_display[2:0] < 4;
            // The first point on each scanline must not connect to the final
            // point from the previous scanline. That stale connection created
            // a bright, false vertical streak along the plot's left border.
            wave_pixel = frame_snapshot_ready && trace_column_valid &&
                         current_channel_valid[render_channel] &&
                         render_seen_mask[render_channel] &&
                         (((!previous_column_valid ||
                            !previous_channel_valid[render_channel]) &&
                           (v_display == current_wave_y ||
                            v_display + 1'b1 == current_wave_y ||
                            v_display == current_wave_y + 1'b1)) ||
                          (previous_column_valid &&
                           previous_channel_valid[render_channel] &&
                           ((v_display >= current_wave_y && v_display <= previous_wave_y) ||
                            (v_display <= current_wave_y && v_display >= previous_wave_y) ||
                            (v_display + 1'b1 == current_wave_y) ||
                            (v_display == current_wave_y + 1'b1))));
            envelope_pixel = frame_snapshot_ready && trace_column_valid &&
                             current_channel_valid[render_channel] &&
                             render_seen_mask[render_channel] &&
                             ((v_display >= current_max_y && v_display <= current_min_y) ||
                              (v_display <= current_max_y && v_display >= current_min_y));
            // Draw every enabled comparison channel from the same frozen
            // frame. The focus trace and its min/max envelope stay on top.
            for (trace_index = 0; trace_index < 6; trace_index = trace_index + 1) begin
                if (frame_snapshot_ready && trace_column_valid &&
                    render_channel_mask[trace_index] && render_seen_mask[trace_index] &&
                    current_channel_valid[trace_index] &&
                    render_channel != trace_index) begin
                    if ((v_display >= current_channel_max_y[trace_index] &&
                         v_display <= current_channel_min_y[trace_index]) ||
                        (v_display <= current_channel_max_y[trace_index] &&
                         v_display >= current_channel_min_y[trace_index])) begin
                        secondary_envelope_pixel = 1'b1;
                        secondary_envelope_color = dim_trace_color(trace_index[2:0]);
                    end
                end
                if (frame_snapshot_ready && trace_column_valid &&
                    render_channel_mask[trace_index] && render_seen_mask[trace_index] &&
                    current_channel_valid[trace_index] &&
                    render_channel != trace_index &&
                    (((!previous_column_valid ||
                       !previous_channel_valid[trace_index]) &&
                      (v_display == current_channel_y[trace_index] ||
                       v_display + 1'b1 == current_channel_y[trace_index] ||
                       v_display == current_channel_y[trace_index] + 1'b1)) ||
                     (previous_column_valid && previous_channel_valid[trace_index] &&
                      ((v_display >= current_channel_y[trace_index] &&
                        v_display <= previous_channel_y[trace_index]) ||
                       (v_display <= current_channel_y[trace_index] &&
                        v_display >= previous_channel_y[trace_index]) ||
                       v_display + 1'b1 == current_channel_y[trace_index] ||
                       v_display == current_channel_y[trace_index] + 1'b1)))) begin
                    secondary_wave_pixel = 1'b1;
                    secondary_color = trace_color(trace_index[2:0]);
                end
            end
            if (minor_grid) begin red_next=4'h0;green_next=4'h2;blue_next=4'h2;end
            if (major_grid) begin red_next=4'h0;green_next=4'h4;blue_next=4'h4;end
            if (border_pixel) begin red_next=4'h2;green_next=4'h7;blue_next=4'h8;end
            if (trigger_pixel) begin red_next=4'hf;green_next=4'h8;blue_next=4'h0;end
            if (trigger_position_pixel) begin red_next=4'hf;green_next=4'h8;blue_next=4'h0;end
            if (secondary_envelope_pixel) begin
                {red_next, green_next, blue_next} = secondary_envelope_color;
            end
            if (secondary_wave_pixel) begin
                red_next=secondary_color[11:8];green_next=secondary_color[7:4];blue_next=secondary_color[3:0];
            end
            if (envelope_pixel) begin red_next=4'h1;green_next=4'h9;blue_next=4'h7;end
            if (wave_pixel) begin
                {red_next, green_next, blue_next} = trace_color(render_channel);
            end
        end else if (v_display > PLOT_BOTTOM && v_display <= PLOT_BOTTOM + 4 &&
                     (h_display==40 || h_display==98 || h_display==155 || h_display==213 ||
                      h_display==270 || h_display==328 || h_display==385 || h_display==443 ||
                      h_display==500 || h_display==558 || h_display==615)) begin
            red_next=4'h2;green_next=4'h7;blue_next=4'h8;
        end else if (v_display < 38) begin
            red_next=4'h0;green_next=4'h2;blue_next=4'h3;
        end else if (v_display >= 396) begin
            red_next=4'h0;green_next=4'h2;blue_next=4'h3;
        end
        if (status_rule_pixel) begin
            red_next=4'h1;green_next=4'h6;blue_next=4'h7;
        end
        if (text_pixel) begin
            if (header_text) begin
                if (render_channel_mask[legend_channel]) begin
                    {red_next, green_next, blue_next} = trace_color(legend_channel);
                end else begin
                    red_next=4'h5;green_next=4'h6;blue_next=4'h7;
                end
            end else if (v_display[9:3] == 50 || v_display[9:3] == 53 || v_display[9:3] == 56) begin
                red_next=4'h2;green_next=4'hd;blue_next=4'hf;
            end else begin
                red_next=4'hb;green_next=4'he;blue_next=4'hf;
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            VGA_R <= 4'd0; VGA_G <= 4'd0; VGA_B <= 4'd0;
            VGA_HS <= 1'b1; VGA_VS <= 1'b1;
            previous_wave_y <= 10'd210;
            for (pipeline_index = 0; pipeline_index < 6; pipeline_index = pipeline_index + 1) begin
                current_channel_y[pipeline_index] <= 10'd210;
                current_channel_min_y[pipeline_index] <= 10'd210;
                current_channel_max_y[pipeline_index] <= 10'd210;
                previous_channel_y[pipeline_index] <= 10'd210;
            end
            current_wave_y <= 10'd210;
            current_channel_valid <= 6'd0;
            previous_channel_valid <= 6'd0;
            current_min_y <= 10'd210;
            current_max_y <= 10'd210;
            trigger_wave_y <= 10'd210;
        end else if (pixel_phase) begin
            current_wave_y <= waveform_y(read_sample);
            current_channel_valid <= read_channel_valid;
            for (pipeline_index = 0; pipeline_index < 6; pipeline_index = pipeline_index + 1) begin
                current_channel_y[pipeline_index] <= waveform_y(read_channel_traces[pipeline_index*12 +: 12]);
                current_channel_min_y[pipeline_index] <= waveform_y(read_channel_min[pipeline_index*12 +: 12]);
                current_channel_max_y[pipeline_index] <= waveform_y(read_channel_max[pipeline_index*12 +: 12]);
            end
            current_min_y <= waveform_y(read_min_sample);
            current_max_y <= waveform_y(read_max_sample);
            trigger_wave_y <= waveform_y(render_trigger_level);
            VGA_HS <= ~((h_display >= H_VISIBLE+H_FRONT) &&
                        (h_display < H_VISIBLE+H_FRONT+H_SYNC));
            VGA_VS <= ~((v_display >= V_VISIBLE+V_FRONT) &&
                        (v_display < V_VISIBLE+V_FRONT+V_SYNC));
            if (h_display < H_VISIBLE && v_display < V_VISIBLE) begin
                VGA_R <= red_next; VGA_G <= green_next; VGA_B <= blue_next;
            end else begin
                VGA_R <= 4'd0; VGA_G <= 4'd0; VGA_B <= 4'd0;
            end
            if (h_display == PLOT_LEFT) previous_wave_y <= current_wave_y;
            else if (h_display >= PLOT_LEFT && h_display <= PLOT_RIGHT)
                previous_wave_y <= current_wave_y;
            if (h_display >= PLOT_LEFT && h_display <= PLOT_RIGHT)
                for (pipeline_index = 0; pipeline_index < 6; pipeline_index = pipeline_index + 1)
                    previous_channel_y[pipeline_index] <= current_channel_y[pipeline_index];
            if (h_display >= PLOT_LEFT && h_display <= PLOT_RIGHT)
                previous_channel_valid <= current_channel_valid;
        end
    end
endmodule
