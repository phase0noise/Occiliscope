-- Oscilloscope top level for the DE10-Lite.
--
-- UART TX: D5 CH AH AL PH PM PL VALUE XOR (checked binary telemetry)
-- UART RX: set:CCCC:FFFF:GGGG\n
--
-- ASCII control: CCCC selects ADC input 0..5, FFFF sets VALUE 0..99,
-- and GGGG is reserved. Binary control and telemetry: docs/UART_PROTOCOL.md.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity oscilloscope is
    port (
        MAX10_CLK1_50 : in    std_logic;
        KEY           : in    std_logic_vector(1 downto 0);
        SW0           : in    std_logic;
        SW8           : in    std_logic;
        SW9           : in    std_logic;
        LEDR          : out   std_logic_vector(9 downto 0);
        HEX0          : out   std_logic_vector(7 downto 0);
        HEX1          : out   std_logic_vector(7 downto 0);
        HEX2          : out   std_logic_vector(7 downto 0);
        HEX3          : out   std_logic_vector(7 downto 0);
        HEX4          : out   std_logic_vector(7 downto 0);
        HEX5          : out   std_logic_vector(7 downto 0);
        VGA_R         : out   std_logic_vector(3 downto 0);
        VGA_G         : out   std_logic_vector(3 downto 0);
        VGA_B         : out   std_logic_vector(3 downto 0);
        VGA_HS        : out   std_logic;
        VGA_VS        : out   std_logic;
        UART_TX_PIN   : out   std_logic;
        UART_RX_PIN   : in    std_logic;
        GEN_GPIO28    : out   std_logic;
        GEN_GPIO30    : out   std_logic
    );
end entity oscilloscope;

architecture rtl of oscilloscope is
    constant CLOCK_FREQUENCY_HZ : integer := 50000000;
    constant UART_BAUD_RATE     : integer := 115200;
    constant UART_PACKET_BYTES  : integer := 9;

    function next_enabled_channel(
        current_channel : integer;
        enabled_mask    : std_logic_vector(5 downto 0)) return integer is
        variable candidate : integer range 0 to 11;
    begin
        for offset in 1 to 6 loop
            candidate := current_channel + offset;
            if candidate >= 6 then candidate := candidate - 6; end if;
            if enabled_mask(candidate) = '1' then return candidate; end if;
        end loop;
        return current_channel;
    end function;

    component SEG7_LUT_6
        port (
            oSEG0 : out std_logic_vector(6 downto 0);
            oSEG1 : out std_logic_vector(6 downto 0);
            oSEG2 : out std_logic_vector(6 downto 0);
            oSEG3 : out std_logic_vector(6 downto 0);
            oSEG4 : out std_logic_vector(6 downto 0);
            oSEG5 : out std_logic_vector(6 downto 0);
            iDIG  : in  std_logic_vector(23 downto 0)
        );
    end component;

    component uart_tx
        generic (
            CLOCK_FREQ : integer := CLOCK_FREQUENCY_HZ;
            BAUD_RATE  : integer := UART_BAUD_RATE
        );
        port (
            clk      : in  std_logic;
            reset    : in  std_logic;
            high_speed : in std_logic;
            tx_start : in  std_logic;
            tx_data  : in  std_logic_vector(7 downto 0);
            tx       : out std_logic;
            tx_ready : out std_logic
        );
    end component;

    component uart_rx
        generic (
            CLOCK_FREQ : integer := CLOCK_FREQUENCY_HZ;
            BAUD_RATE  : integer := UART_BAUD_RATE
        );
        port (
            clk      : in  std_logic;
            reset    : in  std_logic;
            high_speed : in std_logic;
            rx       : in  std_logic;
            rx_data  : out std_logic_vector(7 downto 0);
            rx_valid : out std_logic;
            rx_frame_error : out std_logic
        );
    end component;

    component slide_adc
        port (
            clk              : in  std_logic;
            reset_n          : in  std_logic;
            channel_select   : in  std_logic_vector(4 downto 0);
            adc_sys_clk      : out std_logic;
            response_valid   : out std_logic;
            response_channel : out std_logic_vector(4 downto 0);
            response_data    : out std_logic_vector(11 downto 0)
        );
    end component;

    component scope_vga
        port (
            clk               : in  std_logic;
            reset             : in  std_logic;
            sample_data       : in  std_logic_vector(11 downto 0);
            sample_strobe     : in  std_logic;
            scan_sample_data  : in  std_logic_vector(11 downto 0);
            scan_sample_strobe : in std_logic;
            scan_sample_channel : in std_logic_vector(2 downto 0);
            channel           : in  std_logic_vector(2 downto 0);
            channel_mask      : in  std_logic_vector(5 downto 0);
            channel_samples   : in  std_logic_vector(71 downto 0);
            timebase          : in  std_logic_vector(3 downto 0);
            vertical_scale    : in  std_logic_vector(1 downto 0);
            vertical_position : in  std_logic_vector(6 downto 0);
            trigger_mode      : in  std_logic_vector(1 downto 0);
            trigger_level     : in  std_logic_vector(11 downto 0);
            grid_enable       : in  std_logic;
            run_enable        : in  std_logic;
            manual_mode       : in  std_logic;
            trigger_position  : in  std_logic_vector(1 downto 0);
            single_shot       : in  std_logic;
            average_mode      : in  std_logic_vector(1 downto 0);
            stabilize_enable  : in  std_logic;
            sample_period_cycles : in std_logic_vector(23 downto 0);
            full_scale_mv     : in  std_logic_vector(15 downto 0);
            live_request      : in  std_logic;
            live_metadata_request : in std_logic;
            live_tx_data      : out std_logic_vector(7 downto 0);
            live_tx_valid     : out std_logic;
            live_tx_pop       : in  std_logic;
            VGA_R             : out std_logic_vector(3 downto 0);
            VGA_G             : out std_logic_vector(3 downto 0);
            VGA_B             : out std_logic_vector(3 downto 0);
            VGA_HS            : out std_logic;
            VGA_VS            : out std_logic
        );
        end component;

    component scope_fft
        port (
            clk, reset, request, cancel : in std_logic;
            requested_timebase : in std_logic_vector(3 downto 0);
            request_id : in std_logic_vector(15 downto 0);
            sample_data : in std_logic_vector(11 downto 0);
            sample_strobe : in std_logic;
            channel : in std_logic_vector(2 downto 0);
            full_scale_mv : in std_logic_vector(15 downto 0);
            config_fingerprint : in std_logic_vector(31 downto 0);
            busy : out std_logic;
            tx_data : out std_logic_vector(7 downto 0);
            tx_valid : out std_logic;
            tx_pop : in std_logic
        );
    end component;

    component scope_capture
        generic (
            DEPTH : integer := 8192
        );
        port (
            clk                   : in  std_logic;
            reset                 : in  std_logic;
            rx_byte               : in  std_logic_vector(7 downto 0);
            rx_valid              : in  std_logic;
            rx_frame_error        : in  std_logic;
            legacy_busy           : in  std_logic;
            rx_busy               : out std_logic;
            sample_data           : in  std_logic_vector(11 downto 0);
            sample_strobe         : in  std_logic;
            sample_channel        : in  std_logic_vector(2 downto 0);
            selected_channel      : in  std_logic_vector(2 downto 0);
            average_mode          : in  std_logic_vector(1 downto 0);
            timebase              : in  std_logic_vector(3 downto 0);
            trigger_mode          : in  std_logic_vector(1 downto 0);
            trigger_level         : in  std_logic_vector(11 downto 0);
            trigger_position      : in  std_logic_vector(1 downto 0);
            sample_period_cycles  : in  std_logic_vector(23 downto 0);
            full_scale_mv         : in  std_logic_vector(15 downto 0);
            config_fingerprint    : in  std_logic_vector(31 downto 0);
            tx_data               : out std_logic_vector(7 downto 0);
            tx_valid              : out std_logic;
            tx_pop                : in  std_logic;
            capture_running       : out std_logic;
            capture_complete      : out std_logic;
            capture_valid         : out std_logic;
            capture_invalid       : out std_logic
        );
    end component;

    type uart_byte_array_t is array (0 to UART_PACKET_BYTES - 1) of
        std_logic_vector(7 downto 0);

    signal reset                  : std_logic;
    signal selected_channel       : integer range 0 to 5 := 0;
    signal channel_mask           : std_logic_vector(5 downto 0) := "000001";
    signal scan_channel_adc       : integer range 0 to 5 := 0;
    signal channel_mask_meta_adc  : std_logic_vector(5 downto 0) := "000001";
    signal channel_mask_sync_adc  : std_logic_vector(5 downto 0) := "000001";
    signal setting_1              : integer range 0 to 9999 := 0;
    signal adc_channel_command    : std_logic_vector(4 downto 0);

    signal adc_sys_clk            : std_logic;
    signal adc_response_valid     : std_logic;
    signal adc_response_channel   : std_logic_vector(4 downto 0);
    signal adc_response_data      : std_logic_vector(11 downto 0);
    signal adc_sample_adc         : std_logic_vector(11 downto 0) := (others => '0');
    signal adc_sample_channel_adc : std_logic_vector(2 downto 0) := (others => '0');
    signal adc_sum_adc            : unsigned(17 downto 0) := (others => '0');
    signal adc_average_count_adc  : integer range 0 to 63 := 0;
    signal adc_filter_channel_adc : std_logic_vector(4 downto 0) := (others => '0');
    signal adc_average_meta_adc   : std_logic_vector(1 downto 0) := "00";
    signal adc_average_sync_adc   : std_logic_vector(1 downto 0) := "00";
    signal adc_filter_average_adc : std_logic_vector(1 downto 0) := "00";
    signal adc_sample_toggle_adc  : std_logic := '0';
    signal adc_seen_adc           : std_logic := '0';
    signal adc_toggle_meta        : std_logic := '0';
    signal adc_toggle_sync        : std_logic := '0';
    signal adc_toggle_previous    : std_logic := '0';
    signal adc_seen_meta          : std_logic := '0';
    signal adc_seen_sync          : std_logic := '0';
    signal adc_sample_strobe      : std_logic := '0';
    signal adc_scan_strobe        : std_logic := '0';
    signal adc_scan_sample        : std_logic_vector(11 downto 0) := (others => '0');
    signal adc_scan_channel       : std_logic_vector(2 downto 0) := (others => '0');
    signal vga_sample             : integer range 0 to 4095 := 0;
    type channel_sample_array_t is array (0 to 5) of integer range 0 to 4095;
    signal channel_samples        : channel_sample_array_t := (others => 0);
    signal telemetry_channel      : integer range 0 to 5 := 0;
    signal adc_interval_counter   : unsigned(23 downto 0) := (others => '0');
    signal adc_sample_period      : unsigned(23 downto 0) := to_unsigned(800, 24);

    signal rx_byte                : std_logic_vector(7 downto 0);
    signal rx_byte_valid          : std_logic;
    signal rx_frame_error         : std_logic;
    signal rx_position            : integer range 0 to 18 := 0;
    signal rx_idle_count          : integer range 0 to 5000000 := 0;
    signal rx_discard             : std_logic := '0';
    signal rx_channel_value       : integer range 0 to 9999 := 0;
    signal rx_setting_1_value     : integer range 0 to 9999 := 0;
    signal rx_setting_2_value     : integer range 0 to 9999 := 0;
    signal rx_binary_state        : integer range 0 to 3 := 0;
    signal rx_binary_channel      : integer range 0 to 5 := 0;
    signal rx_binary_value        : integer range 0 to 99 := 0;
    signal rx_scan_state          : integer range 0 to 4 := 0;
    signal rx_scan_mask           : std_logic_vector(5 downto 0) := "000001";
    signal rx_scan_focus          : integer range 0 to 5 := 0;
    signal rx_scan_value          : integer range 0 to 99 := 0;
    signal rx_display_state       : integer range 0 to 8 := 0;
    signal rx_display_checksum    : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_display_timebase    : integer range 0 to 10 := 0;
    signal rx_display_scale       : integer range 0 to 3 := 0;
    signal rx_display_position    : integer range 0 to 100 := 50;
    signal rx_display_trigger     : integer range 0 to 3 := 3;
    signal rx_display_level_high  : std_logic_vector(3 downto 0) := x"8";
    signal rx_display_level_low   : std_logic_vector(7 downto 0) := x"00";
    signal rx_display_flags       : std_logic_vector(7 downto 0) := x"03";
    signal rx_cal_state           : integer range 0 to 3 := 0;
    signal rx_cal_high            : std_logic_vector(7 downto 0) := x"13";
    signal rx_cal_low             : std_logic_vector(7 downto 0) := x"88";
    signal rx_gen_state           : integer range 0 to 11 := 0;
    signal rx_gen_checksum        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_gen_index           : integer range 0 to 1 := 0;
    signal rx_gen_period          : std_logic_vector(31 downto 0) := x"0000C350";
    signal rx_gen_high            : std_logic_vector(31 downto 0) := x"000061A8";
    signal rx_gen_enable          : std_logic := '0';
    signal gen0_period            : unsigned(31 downto 0) := to_unsigned(50000, 32);
    signal gen0_high              : unsigned(31 downto 0) := to_unsigned(25000, 32);
    signal gen0_counter           : unsigned(31 downto 0) := (others => '0');
    signal gen0_enable            : std_logic := '0';
    signal gen1_period            : unsigned(31 downto 0) := to_unsigned(50000, 32);
    signal gen1_high              : unsigned(31 downto 0) := to_unsigned(25000, 32);
    signal gen1_counter           : unsigned(31 downto 0) := (others => '0');
    signal gen1_enable            : std_logic := '0';
    signal adc_full_scale_mv      : integer range 1000 to 9999 := 5000;
    signal display_timebase       : integer range 0 to 10 := 0;
    signal display_scale          : integer range 0 to 3 := 0;
    signal display_position       : integer range 0 to 100 := 50;
    signal display_trigger        : integer range 0 to 3 := 3;
    signal display_trigger_level  : integer range 0 to 4095 := 2048;
    signal display_grid           : std_logic := '1';
    signal display_run            : std_logic := '1';
    signal display_trigger_position : integer range 0 to 3 := 1;
    signal display_single         : std_logic := '0';
    signal display_average        : integer range 0 to 3 := 0;
    signal display_stabilize      : std_logic := '0';
    signal command_seen           : std_logic := '0';
    signal command_error          : std_logic := '0';
    signal rx_activity_count      : integer range 0 to 25000000 := 0;

    signal manual_meta, manual_mode : std_logic := '0';
    signal active_channel_mask : std_logic_vector(5 downto 0);
    signal active_channel : integer range 0 to 5;
    signal active_average, active_trigger : integer range 0 to 3;
    signal active_run, active_single, active_stabilize : std_logic;
    signal key_debounced : std_logic_vector(1 downto 0) := (others => '1');
    type debounce_counters_t is array (0 to 1) of integer range 0 to 499999;
    signal key_debounce_count : debounce_counters_t := (others => 0);
    signal key_meta               : std_logic_vector(1 downto 0) := (others => '1');
    signal key_sync               : std_logic_vector(1 downto 0) := (others => '1');
    signal key_previous           : std_logic_vector(1 downto 0) := (others => '1');

    signal uart_data              : uart_byte_array_t := (others => x"20");
    signal uart_index             : integer range 0 to UART_PACKET_BYTES - 1 := 0;
    signal tx_byte                : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_trigger             : std_logic := '0';
    signal tx_ready               : std_logic;
    signal tx_pending             : std_logic := '0';
    signal tx_capture_pending     : std_logic := '0';
    signal tx_serial              : std_logic;
    type hex_voltage_array_t is array (0 to 2) of integer range 0 to 9999;
    type hex_bcd_shift_array_t is array (0 to 2) of unsigned(29 downto 0);
    type hex_bcd_array_t is array (0 to 2) of std_logic_vector(15 downto 0);
    signal bcd_shift_voltage      : hex_bcd_shift_array_t := (others => (others => '0'));
    signal bcd_count              : integer range 0 to 14 := 0;
    signal voltage_bcd            : hex_bcd_array_t := (others => (others => '0'));
    signal packet_adc_sample      : std_logic_vector(11 downto 0) := (others => '0');
    signal packet_channel         : std_logic_vector(7 downto 0) := (others => '0');
    signal packet_sample_period   : std_logic_vector(23 downto 0) := (others => '0');
    signal packet_value           : std_logic_vector(7 downto 0) := (others => '0');

    signal capture_tx_data        : std_logic_vector(7 downto 0) := (others => '0');
    signal capture_tx_valid       : std_logic;
    signal capture_tx_pop         : std_logic := '0';
    signal live_request           : std_logic;
    signal live_metadata_request  : std_logic;
    signal live_tx_data           : std_logic_vector(7 downto 0);
    signal live_tx_valid          : std_logic;
    signal live_tx_pop            : std_logic := '0';
    signal tx_stream              : integer range 0 to 3 := 0;
    signal fft_request, fft_cancel, fft_tx_valid, fft_tx_pop, fft_busy : std_logic := '0';
    signal fft_tx_data, rx_fft_checksum : std_logic_vector(7 downto 0) := (others => '0');
    signal fft_timebase : std_logic_vector(3 downto 0) := (others => '0');
    signal fft_request_id : std_logic_vector(15 downto 0) := (others => '0');
    signal rx_fft_state : integer range 0 to 4 := 0;
    signal rx_fft_timebase : std_logic_vector(3 downto 0) := (others => '0');
    signal rx_fft_id : std_logic_vector(15 downto 0) := (others => '0');
    signal capture_config_fingerprint : std_logic_vector(31 downto 0);
    signal capture_config_revision : unsigned(15 downto 0) := (others => '0');
    signal legacy_parser_busy    : std_logic;
    signal capture_rx_busy       : std_logic;

    signal display_digits         : std_logic_vector(23 downto 0);
    signal voltage_mv             : hex_voltage_array_t := (others => 0);
    signal hex_rounded_mv         : hex_voltage_array_t := (others => 0);
    signal hex_segments           : std_logic_vector(41 downto 0);
    signal channel_leds           : std_logic_vector(5 downto 0);
    signal vga_channel_samples    : std_logic_vector(71 downto 0);
begin
    reset <= SW9;
    live_request <= '1' when rx_byte_valid = '1' and rx_byte = x"AB" and
                              legacy_parser_busy = '0' and capture_rx_busy = '0' else '0';
    live_metadata_request <= '1' when rx_byte_valid = '1' and rx_byte = x"AE" and
                              legacy_parser_busy = '0' and capture_rx_busy = '0' else '0';

    -- Two independent synthesizable pulse generators. Configuration arrives
    -- as clock-period and high-time counts, so the FPGA datapath needs only
    -- counters/comparators and produces deterministic 20 ns resolution.
    GEN_GPIO28 <= '1' when gen0_enable = '1' and gen0_counter < gen0_high else '0';
    GEN_GPIO30 <= '1' when gen1_enable = '1' and gen1_counter < gen1_high else '0';

    generator_proc : process(MAX10_CLK1_50)
    begin
        if rising_edge(MAX10_CLK1_50) then
            if reset = '1' then
                gen0_counter <= (others => '0');
                gen1_counter <= (others => '0');
            else
                if gen0_enable = '0' or gen0_counter >= gen0_period - 1 then
                    gen0_counter <= (others => '0');
                else
                    gen0_counter <= gen0_counter + 1;
                end if;
                if gen1_enable = '0' or gen1_counter >= gen1_period - 1 then
                    gen1_counter <= (others => '0');
                else
                    gen1_counter <= gen1_counter + 1;
                end if;
            end if;
        end if;
    end process;

    -- The six phone-visible channels 0..5 map to the MAX 10 ADC command
    -- channels 1..6, which correspond to the six DE10-Lite ADC inputs.
    adc_channel_command <= std_logic_vector(to_unsigned(scan_channel_adc + 1, 5));

    -- A compact configuration fingerprint travels with a deep capture.  The
    -- capture engine compares it continuously so changing display/acquisition
    -- settings cannot leave a record that appears valid under new settings.
    active_channel_mask <= "111111" when manual_mode = '1' else channel_mask;
    active_channel <= 0 when manual_mode = '1' else selected_channel;
    active_average <= 0 when manual_mode = '1' else display_average;
    active_trigger <= 0 when manual_mode = '1' else display_trigger;
    active_run <= '1' when manual_mode = '1' else display_run;
    active_single <= '0' when manual_mode = '1' else display_single;
    active_stabilize <= '0' when manual_mode = '1' else display_stabilize;

    capture_fingerprint_proc : process(all)
    begin
        -- The revision is bumped only when an acquisition-affecting setting
        -- commits.  The packed lower bits retain channel/mode context for
        -- diagnostics while avoiding the live measured sample period.
        capture_config_fingerprint <= std_logic_vector(capture_config_revision) &
            active_channel_mask &
            std_logic_vector(to_unsigned(active_channel, 3)) &
            std_logic_vector(to_unsigned(active_average, 2)) &
            std_logic_vector(to_unsigned(active_trigger, 2)) &
            std_logic_vector(to_unsigned(display_trigger_position, 2)) &
            manual_mode;
    end process;

    legacy_parser_busy <= '1' when rx_position /= 0 or rx_discard = '1' or
                          rx_binary_state /= 0 or rx_scan_state /= 0 or
                          rx_display_state /= 0 or rx_cal_state /= 0 or rx_fft_state /= 0 or
                          rx_gen_state /= 0 else '0';

    -- Pico GP0 (TX) -> FPGA GPIO[8]; Pico GP1 (RX) <- FPGA GPIO[4].
    UART_TX_PIN <= tx_serial;

    adc_core : slide_adc
        port map (
            clk              => MAX10_CLK1_50,
            reset_n          => not reset,
            channel_select   => adc_channel_command,
            adc_sys_clk      => adc_sys_clk,
            response_valid   => adc_response_valid,
            response_channel => adc_response_channel,
            response_data    => adc_response_data
        );

    -- Average selectable power-of-two blocks of genuine MAX 10 conversions.
    -- Division is a wire shift, so this reduces random ADC noise without a
    -- divider or slow software filter.  Channel or averaging changes discard
    -- the partial old block instead of blending unlike acquisitions.
    adc_capture_proc : process(adc_sys_clk)
        variable completed_sum : unsigned(17 downto 0);
        variable shifted_sum   : unsigned(17 downto 0);
        variable target_count  : integer range 1 to 64;
        variable shift_count   : integer range 0 to 6;
    begin
        if rising_edge(adc_sys_clk) then
            if reset = '1' then
                adc_sample_adc        <= (others => '0');
                adc_sample_channel_adc <= (others => '0');
                adc_sum_adc           <= (others => '0');
                adc_average_count_adc <= 0;
                adc_filter_channel_adc <= (others => '0');
                adc_average_meta_adc <= "00";
                adc_average_sync_adc <= "00";
                adc_filter_average_adc <= "00";
                adc_sample_toggle_adc <= '0';
                adc_seen_adc          <= '0';
                scan_channel_adc <= 0;
                channel_mask_meta_adc <= "000001";
                channel_mask_sync_adc <= "000001";
            else
                channel_mask_meta_adc <= active_channel_mask;
                channel_mask_sync_adc <= channel_mask_meta_adc;
                adc_average_meta_adc <= std_logic_vector(to_unsigned(active_average, 2));
                adc_average_sync_adc <= adc_average_meta_adc;
                case adc_average_sync_adc is
                    when "00" => target_count := 1;  shift_count := 0;
                    when "01" => target_count := 4;  shift_count := 2;
                    when "10" => target_count := 16; shift_count := 4;
                    when others => target_count := 64; shift_count := 6;
                end case;
                if channel_mask_sync_adc(scan_channel_adc) = '0' then
                    scan_channel_adc <= next_enabled_channel(scan_channel_adc, channel_mask_sync_adc);
                    adc_sum_adc <= (others => '0');
                    adc_average_count_adc <= 0;
                elsif adc_response_valid = '1' and
                  adc_response_channel = adc_channel_command then
                if target_count = 1 then
                    adc_sample_adc <= adc_response_data;
                    adc_sample_channel_adc <= std_logic_vector(to_unsigned(scan_channel_adc, 3));
                    adc_sum_adc <= (others => '0');
                    adc_average_count_adc <= 0;
                    adc_filter_channel_adc <= adc_response_channel;
                    adc_filter_average_adc <= adc_average_sync_adc;
                    adc_sample_toggle_adc <= not adc_sample_toggle_adc;
                    adc_seen_adc <= '1';
                    scan_channel_adc <= next_enabled_channel(scan_channel_adc, channel_mask_sync_adc);
                elsif adc_average_count_adc = 0 or
                   adc_response_channel /= adc_filter_channel_adc or
                   adc_average_sync_adc /= adc_filter_average_adc then
                    adc_sum_adc <= resize(unsigned(adc_response_data),
                                          adc_sum_adc'length);
                    adc_average_count_adc  <= 1;
                    adc_filter_channel_adc <= adc_response_channel;
                    adc_filter_average_adc <= adc_average_sync_adc;
                elsif adc_average_count_adc = target_count - 1 then
                    completed_sum := adc_sum_adc +
                        resize(unsigned(adc_response_data), adc_sum_adc'length);
                    shifted_sum := shift_right(completed_sum, shift_count);
                    adc_sample_adc <= std_logic_vector(shifted_sum(11 downto 0));
                    adc_sample_channel_adc <= std_logic_vector(to_unsigned(scan_channel_adc, 3));
                    adc_sum_adc           <= (others => '0');
                    adc_average_count_adc <= 0;
                    adc_sample_toggle_adc <= not adc_sample_toggle_adc;
                    adc_seen_adc          <= '1';
                    scan_channel_adc <= next_enabled_channel(scan_channel_adc, channel_mask_sync_adc);
                else
                    adc_sum_adc <= adc_sum_adc +
                        resize(unsigned(adc_response_data), adc_sum_adc'length);
                    adc_average_count_adc <= adc_average_count_adc + 1;
                end if;
                end if;
            end if;
        end if;
    end process;

    adc_clock_crossing_proc : process(MAX10_CLK1_50)
        variable crossed_channel : integer range 0 to 5;
        variable crossed_sample  : integer range 0 to 4095;
    begin
        if rising_edge(MAX10_CLK1_50) then
            if reset = '1' then
                adc_toggle_meta     <= '0';
                adc_toggle_sync     <= '0';
                adc_toggle_previous <= '0';
                adc_seen_meta       <= '0';
                adc_seen_sync       <= '0';
                adc_sample_strobe   <= '0';
                adc_scan_strobe     <= '0';
                adc_scan_sample     <= (others => '0');
                adc_scan_channel    <= (others => '0');
                vga_sample          <= 0;
                channel_samples     <= (others => 0);
                adc_interval_counter <= (others => '0');
                adc_sample_period    <= to_unsigned(800, 24);
            else
                adc_sample_strobe <= '0';
                adc_scan_strobe <= '0';
                adc_toggle_meta <= adc_sample_toggle_adc;
                adc_toggle_sync <= adc_toggle_meta;
                adc_seen_meta   <= adc_seen_adc;
                adc_seen_sync   <= adc_seen_meta;

                if adc_toggle_sync /= adc_toggle_previous then
                    adc_toggle_previous <= adc_toggle_sync;
                    crossed_channel := to_integer(unsigned(adc_sample_channel_adc));
                    crossed_sample := to_integer(unsigned(adc_sample_adc));
                    adc_scan_sample <= std_logic_vector(to_unsigned(crossed_sample, 12));
                    adc_scan_channel <= std_logic_vector(to_unsigned(crossed_channel, 3));
                    adc_scan_strobe <= '1';
                    channel_samples(crossed_channel) <= crossed_sample;
                    if crossed_channel = active_channel then
                        vga_sample <= crossed_sample;
                        adc_sample_strobe <= '1';
                        if adc_interval_counter /= 0 then
                            adc_sample_period <= adc_interval_counter + 1;
                        end if;
                        adc_interval_counter <= (others => '0');
                    elsif adc_interval_counter /= (adc_interval_counter'range => '1') then
                        adc_interval_counter <= adc_interval_counter + 1;
                    end if;
                elsif adc_interval_counter /= (adc_interval_counter'range => '1') then
                    adc_interval_counter <= adc_interval_counter + 1;
                end if;
            end if;
        end if;
    end process;

    u_uart_rx : uart_rx
        generic map (
            CLOCK_FREQ => CLOCK_FREQUENCY_HZ,
            BAUD_RATE  => UART_BAUD_RATE
        )
        port map (
            clk      => MAX10_CLK1_50,
            reset    => reset,
            high_speed => '1',
            rx       => UART_RX_PIN,
            rx_data  => rx_byte,
            rx_valid => rx_byte_valid,
            rx_frame_error => rx_frame_error
        );

    -- Deep capture uses the same crossed, averaged focus-channel samples that
    -- feed VGA.  Its response stream is arbitrated with legacy D5 telemetry
    -- below, so existing browser clients remain usable during migration.
    u_scope_capture : scope_capture
        generic map (
            DEPTH => 8192
        )
        port map (
            clk                  => MAX10_CLK1_50,
            reset                => reset,
            rx_byte              => rx_byte,
            rx_valid             => rx_byte_valid,
            rx_frame_error       => rx_frame_error,
            legacy_busy          => legacy_parser_busy,
            rx_busy              => capture_rx_busy,
            sample_data          => std_logic_vector(to_unsigned(vga_sample, 12)),
            sample_strobe        => adc_sample_strobe,
            sample_channel       => std_logic_vector(to_unsigned(active_channel, 3)),
            selected_channel     => std_logic_vector(to_unsigned(active_channel, 3)),
            average_mode         => std_logic_vector(to_unsigned(active_average, 2)),
            timebase             => std_logic_vector(to_unsigned(display_timebase, 4)),
            trigger_mode         => std_logic_vector(to_unsigned(active_trigger, 2)),
            trigger_level        => std_logic_vector(to_unsigned(display_trigger_level, 12)),
            trigger_position     => std_logic_vector(to_unsigned(display_trigger_position, 2)),
            sample_period_cycles => std_logic_vector(adc_sample_period),
            full_scale_mv        => std_logic_vector(to_unsigned(adc_full_scale_mv, 16)),
            config_fingerprint   => capture_config_fingerprint,
            tx_data              => capture_tx_data,
            tx_valid             => capture_tx_valid,
            tx_pop               => capture_tx_pop,
            capture_running      => open,
            capture_complete     => open,
            capture_valid        => open,
            capture_invalid      => open
        );

    spectrum_engine : scope_fft
        port map (
            clk => MAX10_CLK1_50, reset => reset,
            request => fft_request, cancel => fft_cancel,
            requested_timebase => fft_timebase, request_id => fft_request_id,
            sample_data => std_logic_vector(to_unsigned(vga_sample, 12)),
            sample_strobe => adc_sample_strobe,
            channel => std_logic_vector(to_unsigned(active_channel, 3)),
            full_scale_mv => std_logic_vector(to_unsigned(adc_full_scale_mv, 16)),
            config_fingerprint => capture_config_fingerprint,
            busy => fft_busy, tx_data => fft_tx_data,
            tx_valid => fft_tx_valid, tx_pop => fft_tx_pop
        );

    -- Buttons settle for 10 ms before producing one edge per press.
    -- SW0 overrides phone acquisition settings without erasing them.
    key_sync_proc : process(MAX10_CLK1_50)
    begin
        if rising_edge(MAX10_CLK1_50) then
            if reset = '1' then
                key_meta <= (others => '1');
                key_sync <= (others => '1');
                key_debounced <= (others => '1');
                key_previous <= (others => '1');
                key_debounce_count <= (others => 0);
                manual_meta <= '0'; manual_mode <= '0';
            else
                manual_meta <= SW0; manual_mode <= manual_meta;
                key_meta <= KEY; key_sync <= key_meta;
                key_previous <= key_debounced;
                for button in 0 to 1 loop
                    if key_sync(button) = key_debounced(button) then
                        key_debounce_count(button) <= 0;
                    elsif key_debounce_count(button) = 499999 then
                        key_debounced(button) <= key_sync(button);
                        key_debounce_count(button) <= 0;
                    else
                        key_debounce_count(button) <= key_debounce_count(button) + 1;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    -- Parse exactly "set:CCCC:FFFF:GGGG" followed by LF.  CR bytes are
    -- ignored, so both LF and CR/LF senders work.  Values are committed only
    -- after a complete valid line; malformed lines cannot partially update
    -- the active settings.
    uart_rx_parser_proc : process(MAX10_CLK1_50)
        variable digit_value : integer range 0 to 9;
        variable next_value  : integer range 0 to 9999;
    begin
        if rising_edge(MAX10_CLK1_50) then
            if reset = '1' then
                selected_channel   <= 0;
                channel_mask       <= "000001";
                setting_1          <= 0;
                rx_position        <= 0;
                rx_idle_count      <= 0;
                rx_discard         <= '0';
                rx_channel_value   <= 0;
                rx_setting_1_value <= 0;
                rx_setting_2_value <= 0;
                rx_binary_state    <= 0;
                rx_binary_channel  <= 0;
                rx_binary_value    <= 0;
                rx_scan_state      <= 0;
                rx_scan_mask       <= "000001";
                rx_scan_focus      <= 0;
                rx_scan_value      <= 0;
                rx_display_state   <= 0;
                rx_display_checksum <= (others => '0');
                rx_display_timebase <= 0;
                rx_display_scale <= 0;
                rx_display_position <= 50;
                rx_display_trigger <= 3;
                rx_display_level_high <= x"8";
                rx_display_level_low <= x"00";
                rx_display_flags <= x"03";
                rx_cal_state <= 0;
                rx_cal_high <= x"13";
                rx_cal_low <= x"88";
                rx_fft_state <= 0; fft_request <= '0'; fft_cancel <= '0';
                rx_gen_state <= 0;
                rx_gen_checksum <= (others => '0');
                rx_gen_index <= 0;
                rx_gen_period <= x"0000C350";
                rx_gen_high <= x"000061A8";
                rx_gen_enable <= '0';
                gen0_period <= to_unsigned(50000, 32);
                gen0_high <= to_unsigned(25000, 32);
                gen0_enable <= '0';
                gen1_period <= to_unsigned(50000, 32);
                gen1_high <= to_unsigned(25000, 32);
                gen1_enable <= '0';
                adc_full_scale_mv <= 5000;
                display_timebase <= 0;
                display_scale <= 0;
                display_position <= 50;
                display_trigger <= 3;
                display_trigger_level <= 2048;
                display_grid <= '1';
                display_run <= '1';
                display_trigger_position <= 1;
                display_single <= '0';
                display_average <= 0;
                display_stabilize <= '0';
                command_seen       <= '0';
                command_error      <= '0';
                rx_activity_count  <= 0;
                capture_config_revision <= (others => '0');
            else
                fft_request <= '0'; fft_cancel <= '0';
                if rx_activity_count > 0 then
                    rx_activity_count <= rx_activity_count - 1;
                end if;
                -- Abandon an incomplete line after 100 ms.  This lets the next
                -- command recover even if a newline was lost on the wire.
                if rx_position /= 0 or rx_discard = '1' or
                   rx_binary_state /= 0 or rx_display_state /= 0 or
                   rx_cal_state /= 0 or rx_gen_state /= 0 or rx_fft_state /= 0 or rx_scan_state /= 0 then
                    if rx_byte_valid = '1' then
                        rx_idle_count <= 0;
                    elsif rx_idle_count = 5000000 then
                        rx_position   <= 0;
                        rx_discard    <= '0';
                        rx_binary_state <= 0;
                        rx_display_state <= 0;
                        rx_cal_state <= 0;
                        rx_gen_state <= 0;
                        rx_scan_state <= 0; rx_fft_state <= 0;
                        rx_idle_count <= 0;
                        command_error <= '1';
                    else
                        rx_idle_count <= rx_idle_count + 1;
                    end if;
                else
                    rx_idle_count <= 0;
                end if;

                if rx_frame_error = '1' then
                    rx_binary_state <= 0;
                    rx_display_state <= 0;
                    rx_cal_state <= 0;
                    rx_gen_state <= 0;
                    rx_scan_state <= 0; rx_fft_state <= 0;
                    rx_position   <= 0;
                    rx_discard    <= '0';
                    rx_idle_count <= 0;
                    command_error <= '1';
                end if;

                if key_previous(0) = '1' and key_debounced(0) = '0' then
                    if manual_mode = '1' then
                        if display_timebase < 10 then display_timebase <= display_timebase + 1; end if;
                    elsif selected_channel = 5 then
                        selected_channel <= 0;
                        channel_mask <= "000001";
                    else
                        selected_channel <= selected_channel + 1;
                        channel_mask <= std_logic_vector(shift_left(to_unsigned(1, 6), selected_channel + 1));
                    end if;
                    capture_config_revision <= capture_config_revision + 1;
                elsif key_previous(1) = '1' and key_debounced(1) = '0' then
                    if manual_mode = '1' then
                        if display_timebase > 0 then display_timebase <= display_timebase - 1; end if;
                    elsif selected_channel = 0 then
                        selected_channel <= 5;
                        channel_mask <= "100000";
                    else
                        selected_channel <= selected_channel - 1;
                        channel_mask <= std_logic_vector(shift_left(to_unsigned(1, 6), selected_channel - 1));
                    end if;
                    capture_config_revision <= capture_config_revision + 1;
                end if;

                if rx_byte_valid = '1' then
                    rx_activity_count <= 25000000;
                    -- AA starts the versioned deep-capture command stream.
                    -- The dedicated capture parser receives the same byte;
                    -- discard any partial legacy line here so it cannot turn
                    -- a valid capture request into a spurious error.
                    if capture_rx_busy = '1' then
                        -- The capture parser owns all four bytes after AA.
                        -- Do not interpret its payload as an ASCII command.
                        null;
                    elsif rx_fft_state = 1 then
                        if unsigned(rx_byte) <= 10 then
                            rx_fft_timebase <= rx_byte(3 downto 0);
                            rx_fft_checksum <= rx_fft_checksum xor rx_byte; rx_fft_state <= 2;
                        else rx_fft_state <= 0; command_error <= '1'; end if;
                    elsif rx_fft_state = 2 then
                        rx_fft_id(15 downto 8) <= rx_byte;
                        rx_fft_checksum <= rx_fft_checksum xor rx_byte; rx_fft_state <= 3;
                    elsif rx_fft_state = 3 then
                        rx_fft_id(7 downto 0) <= rx_byte;
                        rx_fft_checksum <= rx_fft_checksum xor rx_byte; rx_fft_state <= 4;
                    elsif rx_fft_state = 4 then
                        rx_fft_state <= 0;
                        if rx_byte = rx_fft_checksum then
                            if fft_busy = '0' then
                                fft_timebase <= rx_fft_timebase; fft_request_id <= rx_fft_id; fft_request <= '1';
                            end if;
                            command_seen <= '1'; command_error <= '0';
                        else command_error <= '1'; end if;
                    elsif rx_byte = x"AC" and legacy_parser_busy = '0' then
                        rx_fft_state <= 1; rx_fft_checksum <= x"AC";
                    elsif rx_byte = x"AD" and legacy_parser_busy = '0' then
                        fft_cancel <= '1';
                    elsif (rx_byte = x"AA" or rx_byte = x"AB" or rx_byte = x"AE") and legacy_parser_busy = '0' then
                        rx_position      <= 0;
                        rx_discard       <= '0';
                        rx_binary_state  <= 0;
                        rx_display_state <= 0;
                        rx_cal_state     <= 0;
                        rx_gen_state     <= 0;
                        rx_scan_state    <= 0;
                    -- Display command: A6 TB SCALE POSITION TRIGGER LEVEL_HI
                    -- LEVEL_LO FLAGS CHECKSUM.  The checksum XORs all prior
                    -- bytes.  Settings commit together after full validation.
                    elsif rx_scan_state = 4 then
                        rx_scan_state <= 0;
                        if rx_byte = (x"A9" xor ("00" & rx_scan_mask) xor
                           std_logic_vector(to_unsigned(rx_scan_focus, 8)) xor
                           std_logic_vector(to_unsigned(rx_scan_value, 8))) and
                           rx_scan_mask /= "000000" and rx_scan_mask(rx_scan_focus) = '1' then
                            channel_mask <= rx_scan_mask;
                            selected_channel <= rx_scan_focus;
                            setting_1 <= rx_scan_value;
                            capture_config_revision <= capture_config_revision + 1;
                            command_seen <= '1';command_error <= '0';
                        else
                            command_error <= '1';
                        end if;
                    elsif rx_scan_state = 1 then
                        if unsigned(rx_byte) > 0 and unsigned(rx_byte) <= 63 then
                            rx_scan_mask <= rx_byte(5 downto 0);rx_scan_state <= 2;
                        else rx_scan_state <= 0;command_error <= '1';end if;
                    elsif rx_scan_state = 2 then
                        if unsigned(rx_byte) <= 5 then
                            rx_scan_focus <= to_integer(unsigned(rx_byte));rx_scan_state <= 3;
                        else rx_scan_state <= 0;command_error <= '1';end if;
                    elsif rx_scan_state = 3 then
                        if unsigned(rx_byte) <= 99 then
                            rx_scan_value <= to_integer(unsigned(rx_byte));rx_scan_state <= 4;
                        else rx_scan_state <= 0;command_error <= '1';end if;
                    elsif rx_gen_state = 11 then
                        rx_gen_state <= 0;
                        if rx_byte = rx_gen_checksum and unsigned(rx_gen_period) >= 25 and
                           unsigned(rx_gen_high) <= unsigned(rx_gen_period) then
                            if rx_gen_index = 0 then
                                gen0_period <= unsigned(rx_gen_period);
                                gen0_high <= unsigned(rx_gen_high);
                                gen0_enable <= rx_gen_enable;
                            else
                                gen1_period <= unsigned(rx_gen_period);
                                gen1_high <= unsigned(rx_gen_high);
                                gen1_enable <= rx_gen_enable;
                            end if;
                            command_seen <= '1'; command_error <= '0';
                        else
                            command_error <= '1';
                        end if;
                    elsif rx_gen_state = 1 then
                        if unsigned(rx_byte) <= 1 then
                            rx_gen_index <= to_integer(unsigned(rx_byte));
                            rx_gen_checksum <= rx_gen_checksum xor rx_byte;
                            rx_gen_state <= 2;
                        else rx_gen_state <= 0; command_error <= '1'; end if;
                    elsif rx_gen_state = 2 then rx_gen_period(31 downto 24) <= rx_byte; rx_gen_checksum <= rx_gen_checksum xor rx_byte; rx_gen_state <= 3;
                    elsif rx_gen_state = 3 then rx_gen_period(23 downto 16) <= rx_byte; rx_gen_checksum <= rx_gen_checksum xor rx_byte; rx_gen_state <= 4;
                    elsif rx_gen_state = 4 then rx_gen_period(15 downto 8) <= rx_byte; rx_gen_checksum <= rx_gen_checksum xor rx_byte; rx_gen_state <= 5;
                    elsif rx_gen_state = 5 then rx_gen_period(7 downto 0) <= rx_byte; rx_gen_checksum <= rx_gen_checksum xor rx_byte; rx_gen_state <= 6;
                    elsif rx_gen_state = 6 then rx_gen_high(31 downto 24) <= rx_byte; rx_gen_checksum <= rx_gen_checksum xor rx_byte; rx_gen_state <= 7;
                    elsif rx_gen_state = 7 then rx_gen_high(23 downto 16) <= rx_byte; rx_gen_checksum <= rx_gen_checksum xor rx_byte; rx_gen_state <= 8;
                    elsif rx_gen_state = 8 then rx_gen_high(15 downto 8) <= rx_byte; rx_gen_checksum <= rx_gen_checksum xor rx_byte; rx_gen_state <= 9;
                    elsif rx_gen_state = 9 then rx_gen_high(7 downto 0) <= rx_byte; rx_gen_checksum <= rx_gen_checksum xor rx_byte; rx_gen_state <= 10;
                    elsif rx_gen_state = 10 then
                        if unsigned(rx_byte) <= 1 then
                            rx_gen_enable <= rx_byte(0);
                            rx_gen_checksum <= rx_gen_checksum xor rx_byte;
                            rx_gen_state <= 11;
                        else rx_gen_state <= 0; command_error <= '1'; end if;
                    elsif rx_cal_state = 3 then
                        rx_cal_state <= 0;
                        if rx_byte = (x"A7" xor rx_cal_high xor rx_cal_low) and
                           (to_integer(unsigned(rx_cal_high)) * 256 +
                            to_integer(unsigned(rx_cal_low))) >= 1000 and
                           (to_integer(unsigned(rx_cal_high)) * 256 +
                            to_integer(unsigned(rx_cal_low))) <= 9999 then
                            adc_full_scale_mv <=
                                to_integer(unsigned(rx_cal_high)) * 256 +
                                to_integer(unsigned(rx_cal_low));
                            capture_config_revision <= capture_config_revision + 1;
                            command_seen <= '1';
                            command_error <= '0';
                        else
                            command_error <= '1';
                        end if;
                    elsif rx_cal_state = 1 then
                        rx_cal_high <= rx_byte;
                        rx_cal_state <= 2;
                    elsif rx_cal_state = 2 then
                        rx_cal_low <= rx_byte;
                        rx_cal_state <= 3;
                    elsif rx_display_state = 8 then
                        rx_display_state <= 0;
                        if rx_byte = rx_display_checksum then
                            display_scale <= rx_display_scale;
                            display_position <= rx_display_position;
                            display_grid <= rx_display_flags(0);
                            -- Manual voltage edits must not replace the saved
                            -- phone trigger, averaging, or acquisition state.
                            if manual_mode = '0' then
                                display_timebase <= rx_display_timebase;
                                display_trigger <= rx_display_trigger;
                                display_trigger_level <=
                                    to_integer(unsigned(rx_display_level_high)) * 256 +
                                    to_integer(unsigned(rx_display_level_low));
                                display_run <= rx_display_flags(1);
                                display_trigger_position <= to_integer(unsigned(rx_display_flags(3 downto 2)));
                                display_single <= rx_display_flags(4);
                                display_average <= to_integer(unsigned(rx_display_flags(6 downto 5)));
                                display_stabilize <= rx_display_flags(7);
                                capture_config_revision <= capture_config_revision + 1;
                            end if;
                            command_seen <= '1';
                            command_error <= '0';
                        else
                            command_error <= '1';
                        end if;
                    elsif rx_display_state = 1 then
                        if unsigned(rx_byte) <= 10 then
                            rx_display_timebase <= to_integer(unsigned(rx_byte));
                            rx_display_checksum <= rx_display_checksum xor rx_byte;
                            rx_display_state <= 2;
                        else rx_display_state <= 0; command_error <= '1'; end if;
                    elsif rx_display_state = 2 then
                        if unsigned(rx_byte) <= 3 then
                            rx_display_scale <= to_integer(unsigned(rx_byte));
                            rx_display_checksum <= rx_display_checksum xor rx_byte;
                            rx_display_state <= 3;
                        else rx_display_state <= 0; command_error <= '1'; end if;
                    elsif rx_display_state = 3 then
                        if unsigned(rx_byte) <= 100 then
                            rx_display_position <= to_integer(unsigned(rx_byte));
                            rx_display_checksum <= rx_display_checksum xor rx_byte;
                            rx_display_state <= 4;
                        else rx_display_state <= 0; command_error <= '1'; end if;
                    elsif rx_display_state = 4 then
                        if unsigned(rx_byte) <= 3 then
                            rx_display_trigger <= to_integer(unsigned(rx_byte));
                            rx_display_checksum <= rx_display_checksum xor rx_byte;
                            rx_display_state <= 5;
                        else rx_display_state <= 0; command_error <= '1'; end if;
                    elsif rx_display_state = 5 then
                        if unsigned(rx_byte) <= 15 then
                            rx_display_level_high <= rx_byte(3 downto 0);
                            rx_display_checksum <= rx_display_checksum xor rx_byte;
                            rx_display_state <= 6;
                        else rx_display_state <= 0; command_error <= '1'; end if;
                    elsif rx_display_state = 6 then
                        rx_display_level_low <= rx_byte;
                        rx_display_checksum <= rx_display_checksum xor rx_byte;
                        rx_display_state <= 7;
                    elsif rx_display_state = 7 then
                        rx_display_flags <= rx_byte;
                        rx_display_checksum <= rx_display_checksum xor rx_byte;
                        rx_display_state <= 8;
                    -- Preferred compact command: A5, channel, VALUE, XOR checksum.
                    -- Seeing A5 at any point immediately resynchronizes the packet.
                    elsif rx_binary_state = 3 then
                        rx_binary_state <= 0;
                        if rx_byte = (x"A5" xor
                           std_logic_vector(to_unsigned(rx_binary_channel, 8)) xor
                           std_logic_vector(to_unsigned(rx_binary_value, 8))) then
                            selected_channel <= rx_binary_channel;
                            channel_mask     <= std_logic_vector(shift_left(to_unsigned(1, 6), rx_binary_channel));
                            setting_1        <= rx_binary_value;
                            capture_config_revision <= capture_config_revision + 1;
                            command_seen     <= '1';
                            command_error    <= '0';
                        else
                            command_error <= '1';
                        end if;
                    elsif rx_discard = '0' and rx_byte = x"A9" then
                        rx_binary_state <= 0;rx_display_state <= 0;rx_cal_state <= 0;
                        rx_gen_state <= 0;rx_scan_state <= 1;
                    elsif rx_discard = '0' and rx_byte = x"A8" then
                        rx_binary_state <= 0;
                        rx_display_state <= 0;
                        rx_cal_state <= 0;
                        rx_gen_checksum <= x"A8";
                        rx_gen_state <= 1;
                    elsif rx_discard = '0' and rx_byte = x"A6" then
                        rx_binary_state <= 0;
                        rx_cal_state <= 0;
                        rx_gen_state <= 0;
                        rx_scan_state <= 0;
                        rx_display_checksum <= x"A6";
                        rx_display_state <= 1;
                    elsif rx_discard = '0' and rx_byte = x"A7" then
                        rx_binary_state <= 0;
                        rx_display_state <= 0;
                        rx_gen_state <= 0;
                        rx_scan_state <= 0;
                        rx_cal_state <= 1;
                    elsif rx_discard = '0' and rx_byte = x"A5" then
                        rx_display_state <= 0;
                        rx_cal_state <= 0;
                        rx_gen_state <= 0;
                        rx_scan_state <= 0;
                        rx_binary_state <= 1;
                    elsif rx_binary_state = 1 then
                        if unsigned(rx_byte) <= 5 then
                            rx_binary_channel <= to_integer(unsigned(rx_byte));
                            rx_binary_state <= 2;
                        else
                            rx_binary_state <= 0;
                            command_error <= '1';
                        end if;
                    elsif rx_binary_state = 2 then
                        if unsigned(rx_byte) <= 99 then
                            rx_binary_value <= to_integer(unsigned(rx_byte));
                            rx_binary_state <= 3;
                        else
                            rx_binary_state <= 0;
                            command_error <= '1';
                        end if;
                    -- Retain the original ASCII command parser for compatibility.
                    elsif rx_byte = x"0D" then
                        null;
                    elsif rx_byte = x"0A" then
                        if rx_discard = '0' and rx_position = 18 then
                            if rx_channel_value <= 5 and rx_setting_1_value <= 99 then
                                selected_channel <= rx_channel_value;
                                channel_mask <= std_logic_vector(shift_left(to_unsigned(1, 6), rx_channel_value));
                                setting_1        <= rx_setting_1_value;
                                capture_config_revision <= capture_config_revision + 1;
                                command_seen     <= '1';
                                command_error    <= '0';
                            else
                                command_error <= '1';
                            end if;
                        elsif rx_position /= 0 or rx_discard = '1' then
                            command_error <= '1';
                        end if;

                        rx_position        <= 0;
                        rx_discard         <= '0';
                        rx_channel_value   <= 0;
                        rx_setting_1_value <= 0;
                        rx_setting_2_value <= 0;
                    elsif rx_discard = '0' then
                        case rx_position is
                            when 0 =>
                                if rx_byte = x"73" then rx_position <= 1;
                                else rx_discard <= '1'; end if; -- s
                            when 1 =>
                                if rx_byte = x"65" then rx_position <= 2;
                                else rx_discard <= '1'; end if; -- e
                            when 2 =>
                                if rx_byte = x"74" then rx_position <= 3;
                                else rx_discard <= '1'; end if; -- t
                            when 3 =>
                                if rx_byte = x"3A" then
                                    rx_channel_value <= 0;
                                    rx_position <= 4;
                                else
                                    rx_discard <= '1';
                                end if;

                            when 4 | 5 | 6 | 7 =>
                                if rx_byte >= x"30" and rx_byte <= x"39" then
                                    digit_value := to_integer(unsigned(rx_byte)) - 48;
                                    next_value := rx_channel_value * 10 + digit_value;
                                    rx_channel_value <= next_value;
                                    rx_position <= rx_position + 1;
                                else
                                    rx_discard <= '1';
                                end if;

                            when 8 =>
                                if rx_byte = x"3A" then
                                    rx_setting_1_value <= 0;
                                    rx_position <= 9;
                                else
                                    rx_discard <= '1';
                                end if;

                            when 9 | 10 | 11 | 12 =>
                                if rx_byte >= x"30" and rx_byte <= x"39" then
                                    digit_value := to_integer(unsigned(rx_byte)) - 48;
                                    next_value := rx_setting_1_value * 10 + digit_value;
                                    rx_setting_1_value <= next_value;
                                    rx_position <= rx_position + 1;
                                else
                                    rx_discard <= '1';
                                end if;

                            when 13 =>
                                if rx_byte = x"3A" then
                                    rx_setting_2_value <= 0;
                                    rx_position <= 14;
                                else
                                    rx_discard <= '1';
                                end if;

                            when 14 | 15 | 16 | 17 =>
                                if rx_byte >= x"30" and rx_byte <= x"39" then
                                    digit_value := to_integer(unsigned(rx_byte)) - 48;
                                    next_value := rx_setting_2_value * 10 + digit_value;
                                    rx_setting_2_value <= next_value;
                                    rx_position <= rx_position + 1;
                                else
                                    rx_discard <= '1';
                                end if;

                            when 18 =>
                                rx_discard <= '1';
                        end case;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Convert CH0..CH2 calibrated voltages to packed BCD in parallel. Each
    -- converter pass takes 14 clocks; the top two digits drive X.X volts.
    bcd_convert_proc : process(MAX10_CLK1_50)
        variable next_voltage   : unsigned(29 downto 0);
    begin
        if rising_edge(MAX10_CLK1_50) then
            if reset = '1' then
                bcd_shift_voltage   <= (others => (others => '0'));
                bcd_count           <= 0;
                voltage_bcd         <= (others => (others => '0'));
            elsif bcd_count = 0 then
                for channel_index in 0 to 2 loop
                    bcd_shift_voltage(channel_index) <=
                        to_unsigned(0, 16) & to_unsigned(hex_rounded_mv(channel_index), 14);
                end loop;
                bcd_count <= 14;
            else
                for channel_index in 0 to 2 loop
                    next_voltage := bcd_shift_voltage(channel_index);
                    for digit in 0 to 3 loop
                        if next_voltage(17 + digit * 4 downto 14 + digit * 4) > 4 then
                            next_voltage(17 + digit * 4 downto 14 + digit * 4) :=
                                next_voltage(17 + digit * 4 downto 14 + digit * 4) + 3;
                        end if;
                    end loop;
                    next_voltage := shift_left(next_voltage, 1);
                    bcd_shift_voltage(channel_index) <= next_voltage;
                    if bcd_count = 1 then
                        voltage_bcd(channel_index) <=
                            std_logic_vector(next_voltage(29 downto 14));
                    end if;
                end loop;
                bcd_count <= bcd_count - 1;
            end if;
        end if;
    end process;

    -- Compact binary telemetry more than doubles the useful phone sample rate
    -- versus the old 21-byte decimal line. It also carries the FPGA-measured
    -- focus sample interval so the phone can label VGA time/div accurately.
    uart_packet_builder_proc : process(MAX10_CLK1_50)
    begin
        if rising_edge(MAX10_CLK1_50) then
            uart_data(0) <= x"D5";
            uart_data(1) <= packet_channel;
            uart_data(2) <= x"0" & packet_adc_sample(11 downto 8);
            uart_data(3) <= packet_adc_sample(7 downto 0);
            uart_data(4) <= packet_sample_period(23 downto 16);
            uart_data(5) <= packet_sample_period(15 downto 8);
            uart_data(6) <= packet_sample_period(7 downto 0);
            uart_data(7) <= packet_value;
            uart_data(8) <= x"D5" xor packet_channel xor
                            (x"0" & packet_adc_sample(11 downto 8)) xor
                            packet_adc_sample(7 downto 0) xor
                            packet_sample_period(23 downto 16) xor
                            packet_sample_period(15 downto 8) xor
                            packet_sample_period(7 downto 0) xor packet_value;
        end if;
    end process;

    uart_tx_control_proc : process(MAX10_CLK1_50)
    begin
        if rising_edge(MAX10_CLK1_50) then
            if reset = '1' then
                uart_index        <= 0;
                tx_byte           <= (others => '0');
                tx_trigger        <= '0';
                tx_pending        <= '0';
                tx_capture_pending <= '0';
                capture_tx_pop    <= '0';
                live_tx_pop <= '0'; fft_tx_pop <= '0'; tx_stream <= 0;
                packet_adc_sample    <= (others => '0');
                packet_channel       <= (others => '0');
                packet_sample_period <= (others => '0');
                packet_value         <= (others => '0');
                telemetry_channel <= 0;
            else
                tx_trigger <= '0';
                capture_tx_pop <= '0';
                live_tx_pop <= '0'; fft_tx_pop <= '0';

                if tx_ready = '1' and tx_pending = '0' then
                    if fft_tx_valid = '1' and uart_index = 0 and
                       (tx_stream /= 2 or live_tx_valid = '0') and
                       (tx_stream /= 1 or capture_tx_valid = '0') then
                        tx_byte <= fft_tx_data; tx_trigger <= '1'; tx_pending <= '1';
                        tx_capture_pending <= '1'; fft_tx_pop <= '1'; tx_stream <= 3;
                    elsif live_tx_valid = '1' and uart_index = 0 and
                       (tx_stream = 2 or capture_tx_valid = '0') and
                       (tx_stream /= 3 or fft_tx_valid = '0') then
                        tx_byte <= live_tx_data;
                        tx_trigger <= '1'; tx_pending <= '1';
                        tx_capture_pending <= '1'; live_tx_pop <= '1';
                        tx_stream <= 2;
                    elsif capture_tx_valid = '1' and uart_index = 0 and
                          (tx_stream /= 2 or live_tx_valid = '0') and
                          (tx_stream /= 3 or fft_tx_valid = '0') then
                        -- Deep-capture bytes have priority over telemetry and
                        -- remain asserted until this handshake is accepted.
                        tx_byte <= capture_tx_data;
                        tx_trigger <= '1';
                        tx_pending <= '1';
                        tx_capture_pending <= '1';
                        capture_tx_pop <= '1';
                        tx_stream <= 1;
                    else
                        tx_stream <= 0;
                        tx_capture_pending <= '0';
                        if uart_index = 0 then
                            packet_adc_sample <= std_logic_vector(
                                to_unsigned(channel_samples(telemetry_channel), 12));
                            packet_channel <= std_logic_vector(to_unsigned(telemetry_channel, 8));
                            packet_sample_period <= std_logic_vector(adc_sample_period);
                            if setting_1 <= 99 then
                                packet_value <= std_logic_vector(to_unsigned(setting_1, 8));
                            else
                                packet_value <= x"63";
                            end if;
                        end if;

                        tx_byte    <= uart_data(uart_index);
                        tx_trigger <= '1';
                        tx_pending <= '1';
                    end if;
                end if;

                if tx_trigger = '1' then
                    tx_pending <= '0';
                    if tx_capture_pending = '0' then
                        if uart_index = UART_PACKET_BYTES - 1 then
                            uart_index <= 0;
                            telemetry_channel <= next_enabled_channel(telemetry_channel, active_channel_mask);
                        else
                            uart_index <= uart_index + 1;
                        end if;
                    end if;
                    tx_capture_pending <= '0';
                end if;
            end if;
        end if;
    end process;

    u_uart_tx : uart_tx
        generic map (
            CLOCK_FREQ => CLOCK_FREQUENCY_HZ,
            BAUD_RATE  => UART_BAUD_RATE
        )
        port map (
            clk      => MAX10_CLK1_50,
            reset    => reset,
            high_speed => '1',
            tx_start => tx_trigger,
            tx_data  => tx_byte,
            tx       => tx_serial,
            tx_ready => tx_ready
        );

    vga_channel_samples(11 downto 0)  <= std_logic_vector(to_unsigned(channel_samples(0), 12));
    vga_channel_samples(23 downto 12) <= std_logic_vector(to_unsigned(channel_samples(1), 12));
    vga_channel_samples(35 downto 24) <= std_logic_vector(to_unsigned(channel_samples(2), 12));
    vga_channel_samples(47 downto 36) <= std_logic_vector(to_unsigned(channel_samples(3), 12));
    vga_channel_samples(59 downto 48) <= std_logic_vector(to_unsigned(channel_samples(4), 12));
    vga_channel_samples(71 downto 60) <= std_logic_vector(to_unsigned(channel_samples(5), 12));

    vga_display : scope_vga
        port map (
            clk               => MAX10_CLK1_50,
            reset             => reset,
            sample_data       => std_logic_vector(to_unsigned(vga_sample, 12)),
            sample_strobe     => adc_sample_strobe,
            scan_sample_data => adc_scan_sample,
            scan_sample_strobe => adc_scan_strobe,
            scan_sample_channel => adc_scan_channel,
            channel           => std_logic_vector(to_unsigned(active_channel, 3)),
            channel_mask      => active_channel_mask,
            channel_samples   => vga_channel_samples,
            timebase          => std_logic_vector(to_unsigned(display_timebase, 4)),
            vertical_scale    => std_logic_vector(to_unsigned(display_scale, 2)),
            vertical_position => std_logic_vector(to_unsigned(display_position, 7)),
            trigger_mode      => std_logic_vector(to_unsigned(active_trigger, 2)),
            trigger_level     => std_logic_vector(to_unsigned(display_trigger_level, 12)),
            grid_enable       => display_grid,
            run_enable        => active_run,
            manual_mode       => manual_mode,
            trigger_position  => std_logic_vector(to_unsigned(display_trigger_position, 2)),
            single_shot       => active_single,
            average_mode      => std_logic_vector(to_unsigned(active_average, 2)),
            stabilize_enable  => active_stabilize,
            sample_period_cycles => std_logic_vector(adc_sample_period),
            full_scale_mv     => std_logic_vector(to_unsigned(adc_full_scale_mv, 16)),
            live_request      => live_request,
            live_metadata_request => live_metadata_request,
            live_tx_data      => live_tx_data,
            live_tx_valid     => live_tx_valid,
            live_tx_pop       => live_tx_pop,
            VGA_R             => VGA_R,
            VGA_G             => VGA_G,
            VGA_B             => VGA_B,
            VGA_HS            => VGA_HS,
            VGA_VS            => VGA_VS
        );

    -- Fixed channel positions make the six digits a quick live reference:
    -- HEX5..4 = CH0, HEX3..2 = CH1, HEX1..0 = CH2. Each pair shows X.X V.
    -- An input disabled on the phone is blank because it is not being sampled.
    hex_voltages : for channel_index in 0 to 2 generate
        voltage_mv(channel_index) <=
            (channel_samples(channel_index) * adc_full_scale_mv + 2048) / 4096;
        -- Nearest tenth of a volt, capped at 9.9 because two digits cannot
        -- display 10.0 even when calibration is set near 10 V full scale.
        hex_rounded_mv(channel_index) <= 9999 when voltage_mv(channel_index) >= 9950
                                         else voltage_mv(channel_index) + 50;
    end generate;
    display_digits <= voltage_bcd(0)(15 downto 8) &
                      voltage_bcd(1)(15 downto 8) &
                      voltage_bcd(2)(15 downto 8);

    seg7_inst : SEG7_LUT_6
        port map (
            oSEG0 => hex_segments(6 downto 0),
            oSEG1 => hex_segments(13 downto 7),
            oSEG2 => hex_segments(20 downto 14),
            oSEG3 => hex_segments(27 downto 21),
            oSEG4 => hex_segments(34 downto 28),
            oSEG5 => hex_segments(41 downto 35),
            iDIG  => display_digits
        );

    HEX0(6 downto 0) <= hex_segments(6 downto 0) when active_channel_mask(2) = '1' else (others => '1');
    HEX1(6 downto 0) <= hex_segments(13 downto 7) when active_channel_mask(2) = '1' else (others => '1');
    HEX2(6 downto 0) <= hex_segments(20 downto 14) when active_channel_mask(1) = '1' else (others => '1');
    HEX3(6 downto 0) <= hex_segments(27 downto 21) when active_channel_mask(1) = '1' else (others => '1');
    HEX4(6 downto 0) <= hex_segments(34 downto 28) when active_channel_mask(0) = '1' else (others => '1');
    HEX5(6 downto 0) <= hex_segments(41 downto 35) when active_channel_mask(0) = '1' else (others => '1');
    HEX0(7) <= '1';
    HEX1(7) <= not active_channel_mask(2);
    HEX2(7) <= '1';
    HEX3(7) <= not active_channel_mask(1);
    HEX4(7) <= '1';
    HEX5(7) <= not active_channel_mask(0);

    channel_leds <= active_channel_mask;

    LEDR(5 downto 0) <= channel_leds;
    LEDR(6)          <= adc_seen_sync;
    LEDR(7)          <= command_seen;
    LEDR(8)          <= command_error;
    LEDR(9)          <= reset;
end architecture rtl;
