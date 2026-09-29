-- Focused protocol/acquisition test for scope_capture.
-- Uses a 64-record instance and a two-sample settling window so the test
-- exercises the same ring/trigger/packet logic without allocating the full
-- 8192-record simulation memory.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity scope_capture_tb is
end entity scope_capture_tb;

architecture test of scope_capture_tb is
    constant CLK_PERIOD : time := 20 ns;
    constant DEPTH      : integer := 64;
    constant PACKET_BYTES : integer := 228;

    signal clk       : std_logic := '0';
    signal reset     : std_logic := '1';
    signal rx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_valid  : std_logic := '0';
    signal rx_error  : std_logic := '0';
    signal legacy_busy : std_logic := '0';
    signal sample_data : std_logic_vector(11 downto 0) := (others => '0');
    signal sample_strobe : std_logic := '0';
    signal sample_channel : std_logic_vector(2 downto 0) := "000";
    signal selected_channel : std_logic_vector(2 downto 0) := "000";
    signal average_mode : std_logic_vector(1 downto 0) := "00";
    signal timebase : std_logic_vector(3 downto 0) := "0000";
    signal trigger_mode : std_logic_vector(1 downto 0) := "01";
    signal trigger_level : std_logic_vector(11 downto 0) :=
        std_logic_vector(to_unsigned(1000, 12));
    signal trigger_position : std_logic_vector(1 downto 0) := "01";
    signal sample_period : std_logic_vector(23 downto 0) :=
        std_logic_vector(to_unsigned(800, 24));
    signal full_scale : std_logic_vector(15 downto 0) :=
        std_logic_vector(to_unsigned(5000, 16));
    signal config_fingerprint : std_logic_vector(31 downto 0) := x"12345678";
    signal tx_data : std_logic_vector(7 downto 0);
    signal tx_valid : std_logic;
    signal tx_pop : std_logic := '0';
    signal capture_running : std_logic;
    signal capture_complete : std_logic;
    signal capture_valid : std_logic;
    signal capture_invalid : std_logic;

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
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.scope_capture
        generic map (
            DEPTH => DEPTH,
            SNAPSHOT_DEPTH => 32,
            SETTLE_SAMPLES => 2
        )
        port map (
            clk => clk,
            reset => reset,
            rx_byte => rx_byte,
            rx_valid => rx_valid,
            rx_frame_error => rx_error,
            legacy_busy => legacy_busy,
            sample_data => sample_data,
            sample_strobe => sample_strobe,
            sample_channel => sample_channel,
            selected_channel => selected_channel,
            average_mode => average_mode,
            timebase => timebase,
            trigger_mode => trigger_mode,
            trigger_level => trigger_level,
            trigger_position => trigger_position,
            sample_period_cycles => sample_period,
            full_scale_mv => full_scale,
            config_fingerprint => config_fingerprint,
            tx_data => tx_data,
            tx_valid => tx_valid,
            tx_pop => tx_pop,
            capture_running => capture_running,
            capture_complete => capture_complete,
            capture_valid => capture_valid,
            capture_invalid => capture_invalid
        );

    stimulus : process
        procedure send_byte(value : std_logic_vector(7 downto 0)) is
        begin
            rx_byte <= value;
            rx_valid <= '1';
            wait until rising_edge(clk);
            rx_valid <= '0';
            wait until rising_edge(clk);
        end procedure;

        procedure send_command(
            operation : std_logic_vector(7 downto 0);
            request_id : std_logic_vector(15 downto 0)) is
            variable check : std_logic_vector(7 downto 0);
        begin
            check := x"AA" xor operation xor request_id(15 downto 8) xor
                     request_id(7 downto 0);
            send_byte(x"AA");
            send_byte(operation);
            send_byte(request_id(15 downto 8));
            send_byte(request_id(7 downto 0));
            send_byte(check);
        end procedure;

        procedure drive_sample(value : integer) is
        begin
            sample_data <= std_logic_vector(to_unsigned(value, 12));
            sample_strobe <= '1';
            wait until rising_edge(clk);
            sample_strobe <= '0';
            wait until rising_edge(clk);
        end procedure;

        procedure consume_packet(
            expected_type : std_logic_vector(7 downto 0);
            expected_block : integer;
            check_trigger_sample : boolean := false) is
            variable crc : unsigned(15 downto 0) := x"FFFF";
            variable received_crc : std_logic_vector(15 downto 0);
            variable trigger_hi : integer := 0;
        begin
            while tx_valid /= '1' loop
                wait until rising_edge(clk);
            end loop;
            for index in 0 to PACKET_BYTES - 1 loop
                assert tx_valid = '1'
                    report "capture packet dropped before fixed length"
                    severity failure;
                if index = 0 then
                    assert tx_data = x"D6" report "bad D6 packet magic"
                        severity failure;
                elsif index = 1 then
                    assert tx_data = x"01" report "bad protocol version"
                        severity failure;
                elsif index = 2 then
                    assert tx_data = expected_type report "unexpected packet type"
                        severity failure;
                elsif index = 8 then
                    assert to_integer(unsigned(tx_data)) = expected_block / 256
                        severity failure;
                elsif index = 9 then
                    assert to_integer(unsigned(tx_data)) = expected_block mod 256
                        severity failure;
                elsif check_trigger_sample and index = 34 + 16 * 6 then
                    trigger_hi := to_integer(unsigned(tx_data));
                elsif check_trigger_sample and index = 34 + 16 * 6 + 1 then
                    assert trigger_hi * 16 + to_integer(unsigned(tx_data)) = 1005
                        report "slow-ramp trigger sample was not at trigger_index"
                        severity failure;
                end if;
                if index <= 225 then
                    crc := crc16_step(crc, tx_data);
                elsif index = 226 then
                    received_crc(15 downto 8) := tx_data;
                else
                    received_crc(7 downto 0) := tx_data;
                end if;
                tx_pop <= '1';
                wait until rising_edge(clk);
                tx_pop <= '0';
            end loop;
            assert received_crc = std_logic_vector(crc)
                report "capture packet CRC mismatch" severity failure;
            wait until rising_edge(clk);
        end procedure;
    begin
        wait for 3 * CLK_PERIOD;
        reset <= '0';

        -- A legacy frame owns the line.  AA payload bytes are ignored until
        -- the shared ownership signal returns idle.
        legacy_busy <= '1';
        send_command(x"01", x"00AA");
        wait for 2 * CLK_PERIOD;
        assert tx_valid = '0'
            report "capture parser stole a legacy-owned AA sequence"
            severity failure;
        legacy_busy <= '0';

        -- ARM acknowledgement proves command framing and request ownership.
        send_command(x"01", x"0042");
        consume_packet(x"01", 0);
        assert capture_running = '1' report "ARM did not start capture"
            severity failure;

        -- Two samples settle; 64 low samples fill the ring and arm the
        -- persistent rising Schmitt trigger.  The subsequent slow ramp starts
        -- at 995 (inside hysteresis) and crosses 1004 only after several
        -- samples, which catches edge-only trigger implementations.
        for index in 0 to 63 loop
            drive_sample(500);
        end loop;
        drive_sample(995);
        drive_sample(998);
        drive_sample(1001);
        drive_sample(1005);
        for index in 0 to 46 loop
            drive_sample(700);
        end loop;
        wait for 2 * CLK_PERIOD;
        assert capture_complete = '1' and capture_valid = '1'
            report "capture did not complete after post-trigger samples"
            severity failure;

        send_command(x"02", x"1234");
        consume_packet(x"02", 0, true);
        consume_packet(x"02", 1);
        consume_packet(x"03", 1);

        -- A square wave must trigger as soon as the 25% pre-trigger history
        -- exists; it must not wait for all 64 ring entries before edge search.
        trigger_mode <= "01";
        send_command(x"01", x"4567");
        consume_packet(x"01", 0);
        for index in 0 to 18 loop
            drive_sample(300);
        end loop;
        drive_sample(3000);
        for index in 0 to 46 loop
            drive_sample(3000);
        end loop;
        wait for 2 * CLK_PERIOD;
        assert capture_complete = '1' and capture_valid = '1'
            report "square-wave edge did not trigger after prehistory"
            severity failure;

        -- A VGA snapshot keeps the deep-capture memory available but records
        -- a short stream at the selected VGA decimation. X4 therefore accepts
        -- one of every four focus samples and returns one 32-record block.
        trigger_mode <= "00";
        timebase <= "0010";
        send_command(x"05", x"5678");
        consume_packet(x"01", 0);
        for index in 0 to 229 loop
            drive_sample(1200 + (index mod 32));
        end loop;
        wait for 2 * CLK_PERIOD;
        assert capture_complete = '1' and capture_valid = '1'
            report "decimated VGA snapshot did not complete" severity failure;
        send_command(x"02", x"5678");
        consume_packet(x"02", 0);
        consume_packet(x"03", 0);

        report "scope_capture_tb passed" severity note;
        wait;
    end process;
end architecture test;
