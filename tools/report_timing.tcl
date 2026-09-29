project_open oscilloscope -revision oscilloscope
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 5 -detail full_path -file timing_paths.txt
delete_timing_netlist
project_close
