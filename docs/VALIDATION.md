# Validation

## Last recorded build

The continuous VGA acquisition revision completed a Quartus 23.1std.1 build
for the DE10-Lite at 50 MHz with zero errors. The fitter reported 16,009 logic
elements (32%), 4,439 registers, 888,832 memory bits (53%), and 167 of 288
embedded 9-bit multiplier elements. Slow 85 C timing had 0.291 ns setup
slack and 0.268 ns hold slack. The programming file was
`build/quartus/output_files/oscilloscope.sof`.

These are recorded build results, not measurements from the physical board.
The current sources should be rebuilt after further changes.

## Software checks

From the repository root:

```powershell
node --check web/capture_protocol.js
node --check web/scope.js
node --test web/tests/capture_protocol.test.js
powershell -File tools/build_fpga.ps1
```

The FPGA build requires Quartus Prime Lite 23.1. The Pico W sketch should be
compiled with the `arduino-pico` RP2040 core. Focused HDL test benches are in
`simulation/`; running the VHDL benches locally requires a licensed simulator.

## Board checks still needed

1. Program matching FPGA and Pico firmware builds. Connect the UART wires and
   common ground. Set `SW8` high for 115200 baud.
2. Check VGA, browser live traces, calibration, and both generator controls.
   Enable CH0, CH1, and CH2 together and verify three distinct VGA traces.
   Vary each input separately, then disable one channel and verify its trace
   disappears. At a slow timebase, check narrow pulses in the min/max envelope
   and a steady mean trace for a slowly varying input. Check individual samples
   at X1.
3. Check HEX5..4 for CH0, HEX3..2 for CH1, and HEX1..0 for CH2. Each enabled
   pair should show calibrated volts to one decimal place; disabled pairs
   should be blank.
4. With a signal inside the board and front-end input limits, arm a triggered
   capture. Check its 8,192 records, trigger index, timestamps, and CSV export.
5. Exercise rising and falling triggers with slow ramps and square waves. Test
   free and auto modes on DC, and verify that normal mode waits for an edge.
6. Change channel mask, averaging, or calibration during capture and confirm
   the old record is invalidated.
7. Disconnect the browser during download, reconnect, and retry. Confirm the
   frozen record is unchanged. Repeat at 9600 baud and check gap diagnostics.
8. Test timestamp rollover (the 32-bit 50 MHz counter wraps every 85.899
   seconds), single-shot rearm, zoom, cursors, and export on a phone.

An 8,192-record capture uses 256 data packets and one completion packet,
totaling 58,596 serial bytes. The wire-time lower bound is 5.087 seconds at
115200 baud or 61.038 seconds at 9600 baud. Download time does not set the
sample interval; the FPGA timestamps each sample.
