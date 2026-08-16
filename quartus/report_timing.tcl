# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Name the critical path endpoints. The STA summary reports slack and Fmax but
# not where the path runs, which is what makes a retime targeted rather than
# speculative. Model 1's M0 recorded getting this wrong once: the miss was
# attributed to the wrong stage and retiming there would have cost a pipeline
# stage and moved Fmax by nothing.
project_open [lindex $quartus(args) 0]
create_timing_netlist
read_sdc
update_timing_netlist
set paths [get_timing_paths -setup -npaths 8 -detail path_only]
foreach_in_collection p $paths {
    set slack [get_path_info $p -slack]
    set from  [get_node_info [get_path_info $p -from] -name]
    set to    [get_node_info [get_path_info $p -to]   -name]
    post_message -type info "SLACK $slack"
    post_message -type info "  FROM $from"
    post_message -type info "  TO   $to"
}
