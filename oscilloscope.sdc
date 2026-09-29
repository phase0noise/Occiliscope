create_clock -name MAX10_CLK1_50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_pll_clocks
derive_clock_uncertainty

# Push buttons, reset, and UART RX are asynchronous board inputs.  Their
# metastability handling is implemented in the HDL rather than constrained to
# an external launch clock.
set_false_path -from [get_ports {KEY[*] SW8 SW9 UART_RX_PIN}]

# LEDs, seven-segment displays, and UART TX have no synchronous external
# capture interface, so no board-level output delay applies.
set_false_path -to [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*] UART_TX_PIN GEN_GPIO28 GEN_GPIO30 VGA_R[*] VGA_G[*] VGA_B[*] VGA_HS VGA_VS}]

# The VGA coordinate/scaling pipeline and its destination registers all use
# the alternating 25 MHz pixel enable.  They therefore have two 50 MHz clock
# periods between active captures even though they remain in one clock domain.
set_multicycle_path 2 -setup -to [get_registers {*vga_display|current_wave_y[*] *vga_display|current_channel_y* *vga_display|current_channel_min_y* *vga_display|current_channel_max_y* *vga_display|current_min_y[*] *vga_display|current_max_y[*] *vga_display|trigger_wave_y[*]}]
set_multicycle_path 1 -hold  -to [get_registers {*vga_display|current_wave_y[*] *vga_display|current_channel_y* *vga_display|current_channel_min_y* *vga_display|current_channel_max_y* *vga_display|current_min_y[*] *vga_display|current_max_y[*] *vga_display|trigger_wave_y[*]}]

# Capture packet serialization performs constant divide/modulo decoding, but
# its index changes only after a UART byte is accepted (hundreds of clocks
# apart). The registered byte therefore has three clocks to settle safely.
set_multicycle_path 3 -setup -to [get_registers {*u_scope_capture|packet_byte[*]}]
set_multicycle_path 2 -hold  -to [get_registers {*u_scope_capture|packet_byte[*]}]
