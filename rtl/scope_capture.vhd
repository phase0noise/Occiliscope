-- Deep, triggered capture engine for the browser protocol.
--
-- Records the same averaged focus-channel stream used by the VGA renderer.
-- Snapshot columns retain the mean and extrema of each decimation interval.
--
-- Host command (five bytes): AA OP RID_H RID_L XOR, where XOR is the XOR of
-- the preceding four bytes. Responses are fixed 228-byte D6 packets;
-- see the header layout in the packet_byte process below.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity scope_capture is
    generic (
        DEPTH          : integer := 8192;
        SNAPSHOT_DEPTH : integer := 640;
        SETTLE_SAMPLES : integer := 64
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
end entity scope_capture;

architecture rtl of scope_capture is
    function envelope_depth(depth : integer) return integer is
    begin
        if depth < 1024 then return depth; else return 1024; end if;
    end function;
    function clog2(value : integer) return integer is
        variable result : integer := 0;
        variable v      : integer := value - 1;
    begin
        while v > 0 loop
            result := result + 1;
            v := v / 2;
        end loop;
        return result;
    end function;

    function pretrigger_for(position : std_logic_vector(1 downto 0);
                            depth : integer)
        return integer is
    begin
        if depth = 640 then
            case position is
                when "00" => return 58;
                when "01" => return 144;
                when "10" => return 288;
                when others => return 432;
            end case;
        end if;
        -- These ratios match the VGA choices closely while giving the deep
        -- record a useful amount of history before the trigger.
        case position is
            when "00"   =>
                if depth / 10 < 1 then return 1; else return depth / 10; end if;
            when "01"   => return depth / 4;
            when "10"   => return depth / 2;
            when others => return (depth * 3) / 4;
        end case;
    end function;

    function period_for(period : std_logic_vector(23 downto 0);
                        selected_timebase : std_logic_vector(3 downto 0);
                        decimated : boolean) return std_logic_vector is
        variable extended : unsigned(33 downto 0);
    begin
        extended := resize(unsigned(period), extended'length);
        if decimated then
            extended := shift_left(extended, to_integer(unsigned(selected_timebase)));
        end if;
        if extended > resize(unsigned'(x"FFFFFFFF"), extended'length) then
            return x"FFFFFFFF";
        end if;
        return std_logic_vector(extended(31 downto 0));
    end function;

    function crc16_step(
        crc  : unsigned(15 downto 0);
        data : std_logic_vector(7 downto 0)) return unsigned is
        variable next_crc : unsigned(15 downto 0) := crc;
    begin
        for bit_index in 7 downto 0 loop
            if (next_crc(15) xor data(bit_index)) = '1' then
                next_crc := (next_crc(14 downto 0) & '0') xor x"1021";
            else
                next_crc := next_crc(14 downto 0) & '0';
            end if;
        end loop;
        return next_crc;
    end function;

    constant ADDR_WIDTH  : integer := clog2(DEPTH);
    constant ENVELOPE_ADDR_WIDTH : integer := clog2(envelope_depth(DEPTH));
    constant BLOCK_RECORDS : integer := 32;
    constant HEADER_BYTES  : integer := 34;
    constant DATA_BYTES    : integer := BLOCK_RECORDS * 6;
    constant CRC_BYTES     : integer := 2;
    constant PACKET_BYTES  : integer := HEADER_BYTES + DATA_BYTES + CRC_BYTES;
    type sample_memory_t is array (0 to DEPTH - 1) of
        std_logic_vector(11 downto 0);
    type timestamp_memory_t is array (0 to DEPTH - 1) of
        std_logic_vector(31 downto 0);
    type envelope_memory_t is array (0 to envelope_depth(DEPTH) - 1) of
        std_logic_vector(11 downto 0);

    -- Separate arrays map to M9Ks. Envelopes need only the snapshot history.
    signal sample_memory : sample_memory_t
        /* synthesis ramstyle = "M9K" */;
    signal timestamp_memory : timestamp_memory_t
        /* synthesis ramstyle = "M9K" */;
    signal minimum_memory : envelope_memory_t /* synthesis ramstyle = "M9K" */;
    signal maximum_memory : envelope_memory_t /* synthesis ramstyle = "M9K" */;

    signal timestamp_counter : unsigned(31 downto 0) := (others => '0');
    signal write_pointer     : unsigned(ADDR_WIDTH - 1 downto 0) :=
        (others => '0');
    signal start_pointer     : unsigned(ADDR_WIDTH - 1 downto 0) :=
        (others => '0');
    signal sample_count      : integer range 0 to DEPTH := 0;
    signal record_count      : integer range 0 to DEPTH := 0;
    signal settle_count      : integer range 0 to SETTLE_SAMPLES := 0;
    signal post_remaining    : integer range 0 to DEPTH := 0;
    signal auto_count        : integer range 0 to DEPTH := 0;
    signal pretrigger_count  : integer range 0 to DEPTH := DEPTH / 4;
    signal active_depth      : integer range 1 to DEPTH := DEPTH;
    signal snapshot_mode     : std_logic := '0';
    signal decimation_count  : unsigned(9 downto 0) := (others => '0');
    signal decimation_limit  : unsigned(9 downto 0) := (others => '0');
    signal column_sum : unsigned(21 downto 0) := (others => '0');
    signal column_min : unsigned(11 downto 0) := (others => '1');
    signal column_max : unsigned(11 downto 0) := (others => '0');
    signal column_trigger : std_logic := '0';
    signal trigger_index     : unsigned(15 downto 0) := (others => '0');

    signal previous_sample   : unsigned(11 downto 0) := (others => '0');
    signal previous_valid    : std_logic := '0';
    signal trigger_ready     : std_logic := '0';
    signal triggered         : std_logic := '0';
    signal running           : std_logic := '0';
    signal complete          : std_logic := '0';
    signal valid_record      : std_logic := '0';
    signal invalid_record    : std_logic := '0';

    signal capture_id        : unsigned(15 downto 0) := (others => '0');
    signal latched_config    : std_logic_vector(31 downto 0) :=
        (others => '0');
    signal meta_channel      : std_logic_vector(2 downto 0) := (others => '0');
    signal meta_average      : std_logic_vector(1 downto 0) := (others => '0');
    signal meta_trigger_mode : std_logic_vector(1 downto 0) := (others => '0');
    signal meta_trigger_level : std_logic_vector(11 downto 0) :=
        (others => '0');
    signal meta_sample_period : std_logic_vector(31 downto 0) :=
        (others => '0');
    signal meta_full_scale   : std_logic_vector(15 downto 0) := (others => '0');
    signal meta_timestamp    : std_logic_vector(31 downto 0) := (others => '0');

    -- Five-byte command parser.  cmd_sequence is an event counter so that
    -- parser and capture state remain single-driver clocked processes.
    signal command_state     : integer range 0 to 4 := 0;
    signal command_op        : std_logic_vector(7 downto 0) := (others => '0');
    signal command_id        : std_logic_vector(15 downto 0) := (others => '0');
    signal command_xor       : std_logic_vector(7 downto 0) := (others => '0');
    signal command_sequence  : unsigned(7 downto 0) := (others => '0');
    signal command_seen_seq  : unsigned(7 downto 0) := (others => '0');
    signal pending_command   : std_logic := '0';
    signal pending_op        : std_logic_vector(7 downto 0) := (others => '0');
    signal pending_id        : std_logic_vector(15 downto 0) := (others => '0');

    -- Packet transmitter.  A packet is held until the top-level UART has
    -- accepted each byte; this prevents a slow host from corrupting records.
    signal packet_active     : std_logic := '0';
    signal packet_type       : std_logic_vector(7 downto 0) := x"01";
    signal packet_request_id : std_logic_vector(15 downto 0) := (others => '0');
    signal packet_index      : integer range 0 to PACKET_BYTES - 1 := 0;
    signal packet_block      : integer range 0 to 255 := 0;
    signal packet_blocks     : integer range 0 to 256 := 0;
    signal packet_block_records : integer range 0 to BLOCK_RECORDS := 0;
    signal packet_crc        : unsigned(15 downto 0) := x"FFFF";
    signal crc_work          : unsigned(15 downto 0) := x"FFFF";
    signal crc_bits          : integer range 0 to 8 := 0;
    signal packet_record_addr : unsigned(ADDR_WIDTH - 1 downto 0) :=
        (others => '0');
    signal packet_record_byte : integer range 0 to 9 := 0;
    signal packet_record_number : integer range 0 to BLOCK_RECORDS - 1 := 0;
    signal ram_record_sample : std_logic_vector(11 downto 0) :=
        (others => '0');
    signal ram_record_timestamp : std_logic_vector(31 downto 0) :=
        (others => '0');
    signal ram_read_addr : unsigned(ADDR_WIDTH - 1 downto 0);
    signal ram_record_min : std_logic_vector(11 downto 0);
    signal ram_record_max : std_logic_vector(11 downto 0);
    signal ram_write_min : std_logic_vector(11 downto 0) := (others => '0');
    signal ram_write_max : std_logic_vector(11 downto 0) := (others => '0');
    signal ram_write_enable : std_logic := '0';
    signal ram_write_addr : unsigned(ADDR_WIDTH - 1 downto 0) :=
        (others => '0');
    signal ram_write_sample : std_logic_vector(11 downto 0) :=
        (others => '0');
    signal ram_write_timestamp : std_logic_vector(31 downto 0) :=
        (others => '0');

    signal packet_flags       : std_logic_vector(7 downto 0) := (others => '0');
    signal packet_capture_id  : std_logic_vector(15 downto 0) := (others => '0');
    signal packet_total_count : integer range 0 to DEPTH := 0;
    signal packet_channel     : std_logic_vector(2 downto 0) := (others => '0');
    signal packet_average     : std_logic_vector(1 downto 0) := (others => '0');
    signal packet_trigger_mode : std_logic_vector(1 downto 0) := (others => '0');
    signal packet_trigger_level : std_logic_vector(11 downto 0) :=
        (others => '0');
    signal packet_trigger_index : unsigned(15 downto 0) := (others => '0');
    signal packet_sample_period : std_logic_vector(31 downto 0) :=
        (others => '0');
    signal packet_timestamp : std_logic_vector(31 downto 0) := (others => '0');
    signal packet_config : std_logic_vector(31 downto 0) := (others => '0');
    signal packet_full_scale : std_logic_vector(15 downto 0) := (others => '0');
    signal packet_byte       : std_logic_vector(7 downto 0) := (others => '0');

begin
    capture_running  <= running;
    capture_complete <= complete;
    capture_valid    <= valid_record;
    capture_invalid  <= invalid_record;
    ram_read_addr <= packet_record_addr when packet_active = '1' else start_pointer;

    -- One synchronous read port and one synchronous write port map both
    -- arrays into M9Ks. UART serialization leaves thousands of clocks between
    -- record-address changes, so the registered read latency is harmless.
    capture_ram_proc : process(clk)
    begin
        if rising_edge(clk) then
            if ram_write_enable = '1' then
                sample_memory(to_integer(ram_write_addr)) <= ram_write_sample;
                timestamp_memory(to_integer(ram_write_addr)) <=
                    ram_write_timestamp;
                if snapshot_mode = '1' then
                    minimum_memory(to_integer(ram_write_addr(ENVELOPE_ADDR_WIDTH - 1 downto 0))) <= ram_write_min;
                    maximum_memory(to_integer(ram_write_addr(ENVELOPE_ADDR_WIDTH - 1 downto 0))) <= ram_write_max;
                end if;
            end if;
            ram_record_sample <= sample_memory(to_integer(ram_read_addr));
            ram_record_timestamp <= timestamp_memory(
                to_integer(ram_read_addr));
            ram_record_min <= minimum_memory(to_integer(ram_read_addr(ENVELOPE_ADDR_WIDTH - 1 downto 0)));
            ram_record_max <= maximum_memory(to_integer(ram_read_addr(ENVELOPE_ADDR_WIDTH - 1 downto 0)));
        end if;
    end process;

    -- Host command parser.  An AA seen while a malformed command is pending
    -- re-synchronizes immediately, which is useful after a dropped UART byte.
    command_parser_proc : process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                command_state    <= 0;
                command_op       <= (others => '0');
                command_id       <= (others => '0');
                command_xor      <= (others => '0');
                command_sequence <= (others => '0');
            elsif rx_frame_error = '1' then
                command_state <= 0;
            elsif rx_valid = '1' then
                case command_state is
                    when 0 =>
                        -- A byte inside a settings frame cannot start a capture.
                        if legacy_busy = '0' and rx_byte = x"AA" then
                            command_xor   <= x"AA";
                            command_state <= 1;
                        end if;
                    when 1 =>
                        if rx_byte = x"AA" then
                            command_xor <= x"AA";
                            command_state <= 1;
                        else
                            command_op    <= rx_byte;
                            command_xor   <= command_xor xor rx_byte;
                            command_state <= 2;
                        end if;
                    when 2 =>
                        command_id(15 downto 8) <= rx_byte;
                        command_xor <= command_xor xor rx_byte;
                        command_state <= 3;
                    when 3 =>
                        command_id(7 downto 0) <= rx_byte;
                        command_xor <= command_xor xor rx_byte;
                        command_state <= 4;
                    when others =>
                        command_state <= 0;
                        if rx_byte = command_xor then
                            command_sequence <= command_sequence + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- Capture, trigger, and packet scheduling.  All acquisition decisions are
    -- made in this clock domain after the ADC bundled-data toggle has crossed.
    capture_proc : process(clk)
        variable next_pointer : unsigned(ADDR_WIDTH - 1 downto 0);
        variable candidate_start : unsigned(ADDR_WIDTH - 1 downto 0);
        variable hit : boolean;
        variable lower_level : integer;
        variable upper_level : integer;
        variable sample_integer : integer;
        variable previous_integer : integer;
        variable command_valid : boolean;
        variable event_available : boolean;
        variable event_op : std_logic_vector(7 downto 0);
        variable event_id : std_logic_vector(15 downto 0);
        variable block_count : integer;
        variable records_per_block : integer range 19 to 32;
        variable record_size : integer range 6 to 10;
        variable sum_with_sample : unsigned(21 downto 0);
        variable mean_sample : unsigned(21 downto 0);
        variable minimum_sample : unsigned(11 downto 0);
        variable maximum_sample : unsigned(11 downto 0);
        variable next_record_addr : unsigned(ADDR_WIDTH - 1 downto 0);
        variable next_crc_bit : unsigned(15 downto 0);
        variable arm_depth : integer range 1 to DEPTH;
    begin
        if rising_edge(clk) then
            if reset = '1' then
                timestamp_counter <= (others => '0');
                write_pointer <= (others => '0');
                start_pointer <= (others => '0');
                sample_count <= 0;
                record_count <= 0;
                settle_count <= 0;
                post_remaining <= 0;
                auto_count <= 0;
                pretrigger_count <= DEPTH / 4;
                active_depth <= DEPTH;
                snapshot_mode <= '0';
                decimation_count <= (others => '0');
                decimation_limit <= (others => '0');
                column_sum <= (others => '0');
                column_min <= (others => '1');
                column_max <= (others => '0');
                column_trigger <= '0';
                trigger_index <= (others => '0');
                previous_sample <= (others => '0');
                previous_valid <= '0';
                trigger_ready <= '0';
                triggered <= '0';
                running <= '0';
                complete <= '0';
                valid_record <= '0';
                invalid_record <= '0';
                capture_id <= (others => '0');
                latched_config <= (others => '0');
                meta_channel <= (others => '0');
                meta_average <= (others => '0');
                meta_trigger_mode <= (others => '0');
                meta_trigger_level <= (others => '0');
                meta_sample_period <= (others => '0');
                meta_full_scale <= (others => '0');
                meta_timestamp <= (others => '0');
                command_seen_seq <= (others => '0');
                pending_command <= '0';
                pending_op <= (others => '0');
                pending_id <= (others => '0');
                packet_active <= '0';
                packet_type <= x"01";
                packet_request_id <= (others => '0');
                packet_index <= 0;
                packet_block <= 0;
                packet_blocks <= 0;
                packet_block_records <= 0;
                packet_crc <= x"FFFF";
                crc_work <= x"FFFF";
                crc_bits <= 0;
                packet_record_addr <= (others => '0');
                packet_record_byte <= 0;
                packet_record_number <= 0;
                ram_write_enable <= '0';
                ram_write_addr <= (others => '0');
                ram_write_sample <= (others => '0');
                ram_write_timestamp <= (others => '0');
                packet_flags <= (others => '0');
                packet_capture_id <= (others => '0');
                packet_total_count <= 0;
                packet_channel <= (others => '0');
                packet_average <= (others => '0');
                packet_trigger_mode <= (others => '0');
                packet_trigger_level <= (others => '0');
                packet_trigger_index <= (others => '0');
                packet_sample_period <= (others => '0');
                packet_timestamp <= (others => '0');
                packet_config <= (others => '0');
                packet_full_scale <= (others => '0');
            else
                if snapshot_mode = '1' then records_per_block := 19; record_size := 10;
                else records_per_block := 32; record_size := 6; end if;
                ram_write_enable <= '0';
                timestamp_counter <= timestamp_counter + 1;
                -- One CRC bit per clock keeps the XOR chain off the critical
                -- path. UART byte acceptance leaves time for all eight bits.
                if crc_bits /= 0 then
                    if crc_work(15) = '1' then
                        next_crc_bit := (crc_work(14 downto 0) & '0') xor x"1021";
                    else
                        next_crc_bit := crc_work(14 downto 0) & '0';
                    end if;
                    crc_work <= next_crc_bit;
                    crc_bits <= crc_bits - 1;
                    if crc_bits = 1 then
                        packet_crc <= next_crc_bit;
                    end if;
                end if;
                command_valid := command_sequence /= command_seen_seq;
                event_available := false;
                event_op := (others => '0');
                event_id := (others => '0');

                -- Keep one complete command behind an active response.  A
                -- response packet owns the UART until its CRC has gone out;
                -- command metadata must never replace fields mid-packet.
                if pending_command = '1' and packet_active = '0' then
                    event_available := true;
                    event_op := pending_op;
                    event_id := pending_id;
                    pending_command <= '0';
                end if;
                if command_valid then
                    command_seen_seq <= command_sequence;
                    if not event_available and packet_active = '0' then
                        event_available := true;
                        event_op := command_op;
                        event_id := command_id;
                    elsif pending_command = '0' then
                        pending_command <= '1';
                        pending_op <= command_op;
                        pending_id <= command_id;
                    end if;
                end if;

                -- A settings change invalidates both an in-progress acquisition
                -- and a completed record.  The next ARM then gets a fresh
                -- 64-sample settling window for the ADC averaging pipeline.
                if not command_valid and
                   ((running = '1') or (valid_record = '1')) and
                   config_fingerprint /= latched_config then
                    running <= '0';
                    valid_record <= '0';
                    invalid_record <= '1';
                    complete <= '0';
                end if;

                if event_available then
                    packet_request_id <= event_id;
                    if event_op = x"01" or event_op = x"05" then -- deep ARM / VGA snapshot ARM
                        if event_op = x"05" then arm_depth := SNAPSHOT_DEPTH;
                        else arm_depth := DEPTH; end if;
                        capture_id <= capture_id + 1;
                        latched_config <= config_fingerprint;
                        meta_channel <= selected_channel;
                        meta_average <= average_mode;
                        meta_trigger_mode <= trigger_mode;
                        meta_trigger_level <= trigger_level;
                        meta_sample_period <= period_for(sample_period_cycles, timebase, event_op = x"05");
                        meta_full_scale <= full_scale_mv;
                        pretrigger_count <= pretrigger_for(trigger_position, arm_depth);
                        active_depth <= arm_depth;
                        if event_op = x"05" then
                            snapshot_mode <= '1';
                            decimation_limit <= shift_left(to_unsigned(1, 10), to_integer(unsigned(timebase))) - 1;
                        else
                            snapshot_mode <= '0';
                            decimation_limit <= (others => '0');
                        end if;
                        decimation_count <= (others => '0');
                        column_sum <= (others => '0');
                        column_min <= (others => '1');
                        column_max <= (others => '0');
                        column_trigger <= '0';
                        running <= '1';
                        complete <= '0';
                        valid_record <= '0';
                        invalid_record <= '0';
                        triggered <= '0';
                        previous_valid <= '0';
                        trigger_ready <= '0';
                        sample_count <= 0;
                        record_count <= 0;
                        settle_count <= SETTLE_SAMPLES;
                        post_remaining <= 0;
                        auto_count <= 0;
                        write_pointer <= (others => '0');
                        packet_type <= x"01";
                        packet_flags <= x"01"; -- armed/running; capture is pending
                        packet_capture_id <= std_logic_vector(capture_id + 1);
                        packet_total_count <= 0;
                        packet_channel <= selected_channel;
                        packet_average <= average_mode;
                        packet_trigger_mode <= trigger_mode;
                        packet_trigger_level <= trigger_level;
                        packet_trigger_index <= to_unsigned(
                            pretrigger_for(trigger_position, arm_depth), 16);
                        packet_sample_period <= period_for(sample_period_cycles, timebase, event_op = x"05");
                        packet_timestamp <= (others => '0');
                        packet_config <= config_fingerprint;
                        packet_full_scale <= full_scale_mv;
                        packet_block_records <= 0;
                        packet_index <= 0;
                        packet_crc <= x"FFFF";
                        packet_active <= '1';
                    elsif event_op = x"02" then                 -- DOWNLOAD
                        if packet_active = '0' and valid_record = '1' and
                           complete = '1' then
                            packet_type <= x"02";
                            packet_index <= 0;
                            packet_block <= 0;
                            if snapshot_mode = '1' then
                                block_count := (SNAPSHOT_DEPTH + 18) / 19;
                            else block_count := (record_count + 31) / 32; end if;
                            packet_blocks <= block_count;
                            if record_count >= records_per_block then
                                packet_block_records <= records_per_block;
                            else
                                packet_block_records <= record_count;
                            end if;
                            packet_record_addr <= start_pointer;
                            packet_record_byte <= 0;
                            packet_record_number <= 0;
                            packet_flags <= "000" & invalid_record & triggered &
                                            valid_record & complete & running;
                            packet_capture_id <= std_logic_vector(capture_id);
                            packet_total_count <= record_count;
                            packet_channel <= meta_channel;
                            packet_average <= meta_average;
                            packet_trigger_mode <= meta_trigger_mode;
                            packet_trigger_level <= meta_trigger_level;
                            packet_trigger_index <= trigger_index;
                            packet_sample_period <= meta_sample_period;
                            packet_timestamp <= ram_record_timestamp;
                            packet_config <= latched_config;
                            packet_full_scale <= meta_full_scale;
                            packet_crc <= x"FFFF";
                            packet_active <= '1';
                        else
                            packet_type <= x"7F";
                            packet_index <= 0;
                            packet_crc <= x"FFFF";
                            packet_active <= '1';
                        end if;
                    elsif event_op = x"03" then                 -- STATUS
                        packet_type <= x"01";
                        packet_index <= 0;
                        packet_flags <= "000" & invalid_record & triggered &
                                        valid_record & complete & running;
                        packet_capture_id <= std_logic_vector(capture_id);
                        packet_total_count <= record_count;
                        packet_channel <= meta_channel;
                        packet_average <= meta_average;
                        packet_trigger_mode <= meta_trigger_mode;
                        packet_trigger_level <= meta_trigger_level;
                        packet_trigger_index <= trigger_index;
                        packet_sample_period <= meta_sample_period;
                        packet_timestamp <= ram_record_timestamp;
                        packet_config <= latched_config;
                        packet_full_scale <= meta_full_scale;
                        packet_block_records <= 0;
                        packet_crc <= x"FFFF";
                        packet_active <= '1';
                    elsif event_op = x"04" then                 -- STOP
                        running <= '0';
                        if complete = '0' then
                            valid_record <= '0';
                            invalid_record <= '1';
                        end if;
                        packet_type <= x"01";
                        packet_index <= 0;
                        if complete = '0' then
                            -- STOP invalidates a partial record; reflect the
                            -- new state in the acknowledgement packet.
                            packet_flags <= "000" & '1' & triggered & '0' &
                                            '0' & '0';
                        else
                            packet_flags <= "000" & invalid_record & triggered &
                                            valid_record & complete & '0';
                        end if;
                        packet_capture_id <= std_logic_vector(capture_id);
                        packet_total_count <= record_count;
                        packet_channel <= meta_channel;
                        packet_average <= meta_average;
                        packet_trigger_mode <= meta_trigger_mode;
                        packet_trigger_level <= meta_trigger_level;
                        packet_trigger_index <= trigger_index;
                        packet_sample_period <= meta_sample_period;
                        packet_timestamp <= ram_record_timestamp;
                        packet_config <= latched_config;
                        packet_full_scale <= meta_full_scale;
                        packet_block_records <= 0;
                        packet_crc <= x"FFFF";
                        packet_active <= '1';
                    else
                        packet_type <= x"7F";
                        packet_index <= 0;
                        packet_crc <= x"FFFF";
                        packet_active <= '1';
                    end if;
                elsif running = '1' and sample_strobe = '1' and
                      sample_channel = selected_channel then
                    if settle_count /= 0 then
                        settle_count <= settle_count - 1;
                        decimation_count <= (others => '0');
                        column_sum <= (others => '0');
                        column_min <= (others => '1');
                        column_max <= (others => '0');
                        column_trigger <= '0';
                        previous_valid <= '0';
                        trigger_ready <= '0';
                    elsif decimation_count /= decimation_limit then
                        decimation_count <= decimation_count + 1;
                        column_sum <= column_sum + resize(unsigned(sample_data), 22);
                        if unsigned(sample_data) < column_min then column_min <= unsigned(sample_data); end if;
                        if unsigned(sample_data) > column_max then column_max <= unsigned(sample_data); end if;
                        -- Detect narrow edges before decimation. Keep the
                        -- crossing until its column is committed to memory.
                        if triggered = '0' and sample_count >= pretrigger_count then
                            sample_integer := to_integer(unsigned(sample_data));
                            lower_level := to_integer(unsigned(trigger_level));
                            upper_level := lower_level;
                            if lower_level > 4 then lower_level := lower_level - 4; else lower_level := 0; end if;
                            if upper_level < 4091 then upper_level := upper_level + 4; else upper_level := 4095; end if;
                            if trigger_mode = "01" or trigger_mode = "11" then
                                if sample_integer <= lower_level then trigger_ready <= '1';
                                elsif trigger_ready = '1' and sample_integer >= upper_level then
                                    column_trigger <= '1'; trigger_ready <= '0';
                                end if;
                            elsif trigger_mode = "10" then
                                if sample_integer >= upper_level then trigger_ready <= '1';
                                elsif trigger_ready = '1' and sample_integer <= lower_level then
                                    column_trigger <= '1'; trigger_ready <= '0';
                                end if;
                            end if;
                        end if;
                    else
                        decimation_count <= (others => '0');
                        sum_with_sample := column_sum + resize(unsigned(sample_data), 22);
                        mean_sample := shift_right(sum_with_sample, to_integer(unsigned(timebase)));
                        minimum_sample := column_min;
                        maximum_sample := column_max;
                        if unsigned(sample_data) < minimum_sample then minimum_sample := unsigned(sample_data); end if;
                        if unsigned(sample_data) > maximum_sample then maximum_sample := unsigned(sample_data); end if;
                        column_sum <= (others => '0');
                        column_min <= (others => '1');
                        column_max <= (others => '0');
                        column_trigger <= '0';
                        -- The ADC/averager settings have propagated through
                        -- their crossing by this point; retain the measured
                        -- interval metadata from the settled stream rather
                        -- than the value present at ARM.
                        meta_sample_period <= period_for(sample_period_cycles, timebase,
                                                         snapshot_mode = '1');
                        ram_write_enable <= '1';
                        ram_write_addr <= write_pointer;
                        if snapshot_mode = '1' then
                            ram_write_sample <= std_logic_vector(mean_sample(11 downto 0));
                        else ram_write_sample <= sample_data; end if;
                        ram_write_min <= std_logic_vector(minimum_sample);
                        ram_write_max <= std_logic_vector(maximum_sample);
                        ram_write_timestamp <= std_logic_vector(timestamp_counter);
                        next_pointer := write_pointer + 1;
                        write_pointer <= next_pointer;
                        if sample_count < active_depth then
                            sample_count <= sample_count + 1;
                        end if;

                        sample_integer := to_integer(unsigned(sample_data));
                        previous_integer := to_integer(previous_sample);
                        lower_level := to_integer(unsigned(trigger_level));
                        if lower_level > 4 then lower_level := lower_level - 4;
                        else lower_level := 0; end if;
                        upper_level := to_integer(unsigned(trigger_level));
                        if upper_level < 4091 then upper_level := upper_level + 4;
                        else upper_level := 4095; end if;
                        hit := false;

                        if triggered = '0' then
                            if trigger_mode = "00" then
                                -- Free-run records trigger as soon as the
                                -- ring has its complete prehistory.
                                if sample_count >= active_depth - 1 then
                                    hit := true;
                                end if;
                            elsif trigger_mode = "01" or trigger_mode = "11" then
                                -- Persistent Schmitt state allows a slow ramp
                                -- to cross the two hysteresis thresholds over
                                -- several samples without losing its trigger.
                                if sample_count >= pretrigger_count then
                                    if sample_integer <= lower_level then
                                        trigger_ready <= '1';
                                    elsif trigger_ready = '1' and
                                          sample_integer >= upper_level then
                                        hit := true;
                                        trigger_ready <= '0';
                                    end if;
                                end if;
                                if not hit and trigger_mode = "11" and
                                      sample_count >= pretrigger_count then
                                    if auto_count < active_depth then
                                        auto_count <= auto_count + 1;
                                    else
                                        hit := true;
                                    end if;
                                end if;
                            elsif trigger_mode = "10" then
                                if sample_count >= pretrigger_count then
                                    if sample_integer >= upper_level then
                                        trigger_ready <= '1';
                                    elsif trigger_ready = '1' and
                                          sample_integer <= lower_level then
                                        hit := true;
                                        trigger_ready <= '0';
                                    end if;
                                end if;
                            end if;
                        end if;

                        if triggered = '0' and column_trigger = '1' then hit := true; end if;

                        if hit then
                            triggered <= '1';
                            trigger_index <= to_unsigned(pretrigger_count, 16);
                            post_remaining <= active_depth - pretrigger_count - 1;
                            candidate_start := next_pointer -
                                               to_unsigned(pretrigger_count + 1,
                                                           ADDR_WIDTH);
                            if active_depth - pretrigger_count - 1 = 0 then
                                running <= '0';
                                complete <= '1';
                                valid_record <= '1';
                                invalid_record <= '0';
                                record_count <= active_depth;
                                start_pointer <= candidate_start;
                                meta_timestamp <= (others => '0');
                            end if;
                        elsif triggered = '1' then
                            if post_remaining <= 1 then
                                running <= '0';
                                complete <= '1';
                                valid_record <= '1';
                                invalid_record <= '0';
                                record_count <= active_depth;
                                start_pointer <= next_pointer - to_unsigned(active_depth - 1, ADDR_WIDTH) - 1;
                                meta_timestamp <= (others => '0');
                                post_remaining <= 0;
                            else
                                post_remaining <= post_remaining - 1;
                            end if;
                        end if;

                        previous_sample <= unsigned(sample_data);
                        previous_valid <= '1';
                    end if;
                end if;

                -- Advance a packet only when the top-level UART accepted the
                -- byte currently exposed by packet_byte_proc.
                if packet_active = '1' and tx_pop = '1' then
                    if packet_index <= HEADER_BYTES + DATA_BYTES - 1 then
                        crc_work <= packet_crc xor
                            shift_left(resize(unsigned(packet_byte), 16), 8);
                        crc_bits <= 8;
                    end if;

                    if packet_index = PACKET_BYTES - 1 then
                        if packet_type = x"02" and
                           packet_block + 1 < packet_blocks then
                            packet_block <= packet_block + 1;
                            packet_index <= 0;
                            packet_crc <= x"FFFF";
                            next_record_addr := start_pointer + to_unsigned(
                                (packet_block + 1) * records_per_block,
                                ADDR_WIDTH);
                            packet_record_addr <= next_record_addr;
                            packet_record_byte <= 0;
                            packet_record_number <= 0;
                            if packet_total_count -
                               (packet_block + 1) * records_per_block <
                               records_per_block then
                                packet_block_records <= packet_total_count -
                                    (packet_block + 1) * records_per_block;
                            else
                                packet_block_records <= records_per_block;
                            end if;
                        elsif packet_type = x"02" then
                            -- A final DONE packet makes the end of a download
                            -- unambiguous even if the host is also receiving
                            -- legacy D5 telemetry.
                            packet_type <= x"03";
                            packet_index <= 0;
                            packet_block_records <= 0;
                            packet_crc <= x"FFFF";
                        else
                            packet_active <= '0';
                            packet_index <= 0;
                        end if;
                    else
                        packet_index <= packet_index + 1;
                        if packet_type = x"02" and
                           packet_index >= HEADER_BYTES and
                           packet_index < HEADER_BYTES + DATA_BYTES then
                            if packet_record_byte = record_size - 1 then
                                packet_record_byte <= 0;
                                if packet_record_number < BLOCK_RECORDS - 1 then
                                    packet_record_number <= packet_record_number + 1;
                                end if;
                                if packet_record_number + 1 < packet_block_records then
                                    packet_record_addr <= packet_record_addr + 1;
                                end if;
                            else
                                packet_record_byte <= packet_record_byte + 1;
                            end if;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Packet header and record serialization.  Big-endian fields make the
    -- protocol straightforward in both browser JavaScript and firmware.
    packet_byte_proc : process(clk)
        variable byte_value : std_logic_vector(7 downto 0);
        variable data_index : integer;
        variable record_index : integer;
        variable record_byte : integer;
    begin
      if rising_edge(clk) then
        byte_value := (others => '0');
        case packet_index is
            when 0  => byte_value := x"D6";
            when 1  =>
                if snapshot_mode = '1' then byte_value := x"02";
                else byte_value := x"01"; end if;
            when 2  => byte_value := packet_type;
            when 3  => byte_value := packet_flags;
            when 4  => byte_value := packet_request_id(15 downto 8);
            when 5  => byte_value := packet_request_id(7 downto 0);
            when 6  => byte_value := packet_capture_id(15 downto 8);
            when 7  => byte_value := packet_capture_id(7 downto 0);
            when 8  => byte_value := x"00";
            when 9  => byte_value := std_logic_vector(to_unsigned(packet_block, 8));
            when 10 => byte_value := std_logic_vector(to_unsigned(
                                  packet_total_count / 256, 8));
            when 11 => byte_value := std_logic_vector(to_unsigned(
                                  packet_total_count mod 256, 8));
            when 12 => byte_value := "00000" & packet_channel;
            when 13 => byte_value := "000000" & packet_average;
            when 14 => byte_value := "000000" & packet_trigger_mode;
            when 15 => byte_value := x"0" & packet_trigger_level(11 downto 8);
            when 16 => byte_value := packet_trigger_level(7 downto 0);
            when 17 => byte_value := std_logic_vector(packet_trigger_index(15 downto 8));
            when 18 => byte_value := std_logic_vector(packet_trigger_index(7 downto 0));
            when 19 => byte_value := packet_sample_period(23 downto 16);
            when 20 => byte_value := packet_sample_period(15 downto 8);
            when 21 => byte_value := packet_sample_period(7 downto 0);
            when 22 => byte_value := packet_timestamp(31 downto 24);
            when 23 => byte_value := packet_timestamp(23 downto 16);
            when 24 => byte_value := packet_timestamp(15 downto 8);
            when 25 => byte_value := packet_timestamp(7 downto 0);
            when 26 => byte_value := std_logic_vector(to_unsigned(
                                  packet_block_records, 8));
            when 27 => byte_value := packet_config(31 downto 24);
            when 28 => byte_value := packet_config(23 downto 16);
            when 29 => byte_value := packet_config(15 downto 8);
            when 30 => byte_value := packet_config(7 downto 0);
            when 31 => byte_value := packet_full_scale(15 downto 8);
            when 32 => byte_value := packet_full_scale(7 downto 0);
            when 33 =>
                if snapshot_mode = '1' then byte_value := packet_sample_period(31 downto 24);
                else byte_value := x"00"; end if;
            when others =>
                if packet_index < HEADER_BYTES + DATA_BYTES then
                    data_index := packet_index - HEADER_BYTES;
                    if snapshot_mode = '1' then
                        record_index := data_index / 10;
                        record_byte := data_index mod 10;
                    else
                        record_index := data_index / 6;
                        record_byte := data_index mod 6;
                    end if;
                    if packet_type = x"02" and
                       record_index < packet_block_records then
                        case record_byte is
                            when 0 => byte_value := "0000" &
                                                  ram_record_sample(11 downto 8);
                            when 1 => byte_value := ram_record_sample(7 downto 0);
                            when 2 => byte_value := ram_record_timestamp(31 downto 24);
                            when 3 => byte_value := ram_record_timestamp(23 downto 16);
                            when 4 => byte_value := ram_record_timestamp(15 downto 8);
                            when 5 => byte_value := ram_record_timestamp(7 downto 0);
                            when 6 => byte_value := "0000" & ram_record_min(11 downto 8);
                            when 7 => byte_value := ram_record_min(7 downto 0);
                            when 8 => byte_value := "0000" & ram_record_max(11 downto 8);
                            when others => byte_value := ram_record_max(7 downto 0);
                        end case;
                    else
                        byte_value := x"00";
                    end if;
                elsif packet_index = HEADER_BYTES + DATA_BYTES then
                    byte_value := std_logic_vector(packet_crc(15 downto 8));
                else
                    byte_value := std_logic_vector(packet_crc(7 downto 0));
                end if;
        end case;
        packet_byte <= byte_value;
      end if;
    end process;
    tx_data <= packet_byte;
    tx_valid <= packet_active;
    rx_busy <= '1' when command_state /= 0 else '0';
end architecture rtl;
