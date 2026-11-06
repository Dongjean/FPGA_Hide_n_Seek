# Adds the link, controls and AI bot files to the Vivado project and picks which
# design to build. Safe to run more than once: files already in the project are skipped.
#
# Open FPGA_Hide_n_Seek.xpr, then in the Tcl Console:
#   source [get_property DIRECTORY [current_project]]/add_multiplayer_files.tcl
#
# Afterwards you can switch the design with one command:
#   use_team_top    My_Top_Module   (Basys3_Master.xdc)  <- default
#   use_jb_top      jb_top          (jb_top.xdc only)
#   use_link_test   link_test_top   (Basys3_Master.xdc + link_test.xdc)
# Then reset synthesis and rebuild:
#   reset_run synth_1
#   launch_runs impl_1 -to_step write_bitstream -jobs 4

set m1_srcs [get_property DIRECTORY [current_project]]/FPGA_Hide_n_Seek.srcs

# 1. Forget copies that were added from folders outside the repo
foreach fs {sources_1 constrs_1 sim_1} {
    set outside [get_files -quiet -of_objects [get_filesets $fs] -filter {NAME =~ "*member1_weeks10-12*"}]
    if {[llength $outside] > 0} {
        remove_files -fileset $fs $outside
        puts "removed [llength $outside] outside-the-repo file(s) from $fs"
    }
}

# 2. Old file names (before the rename): take them out of the project and delete
#    them from the repo folder, but only when the renamed file is already there.
set m1_renamed {
    sources_1/new/uart_tx.v           sources_1/new/uart_transmitter.v
    sources_1/new/uart_rx.v           sources_1/new/uart_receiver.v
    sources_1/new/crc8.vh             sources_1/new/crc8_checksum.vh
    sources_1/new/packet_tx.v         sources_1/new/packet_sender.v
    sources_1/new/packet_rx.v         sources_1/new/packet_receiver.v
    sources_1/new/link_status.v       sources_1/new/link_monitor.v
    sources_1/new/debouncer.v         sources_1/new/button_debouncer.v
    sources_1/new/game_controls.v     sources_1/new/board_controls.v
    sources_1/new/game_link.v         sources_1/new/multiplayer_link.v
    sources_1/new/ps2_input.v         sources_1/new/usb_mouse_keyboard.v
    sources_1/new/player_input.v      sources_1/new/player_controls.v
    sources_1/new/opponent.v          sources_1/new/opponent_select.v
    sources_1/new/member1_core.v      sources_1/new/multiplayer_core.v
    sources_1/new/member1_demo_top.v  sources_1/new/jb_top.v
    constrs_1/new/member1_pins.xdc    constrs_1/new/multiplayer_pins.xdc
    constrs_1/new/member1_demo.xdc    constrs_1/new/jb_top.xdc
    sim_1/new/tb_game_controls.v      sim_1/new/tb_board_controls.v
    sim_1/new/tb_game_link.v          sim_1/new/tb_multiplayer_link.v
    sim_1/new/tb_ps2_input.v          sim_1/new/tb_usb_mouse_keyboard.v
    sim_1/new/tb_player_input.v       sim_1/new/tb_player_controls.v
    sim_1/new/tb_opponent.v           sim_1/new/tb_opponent_select.v
    sim_1/new/tb_member1_demo.v       sim_1/new/tb_jb_top.v
}
foreach {old new} $m1_renamed {
    set oname [file tail $old]
    foreach fs {sources_1 constrs_1 sim_1} {
        set f [get_files -quiet -of_objects [get_filesets $fs] -filter "NAME =~ \"*/$oname\""]
        if {[llength $f] > 0} {
            remove_files -fileset $fs $f
            puts "removed old name $oname from $fs"
        }
    }
    if {[file exists $m1_srcs/$old] && [file exists $m1_srcs/$new]} {
        file delete $m1_srcs/$old
        puts "deleted old file $old"
    }
}
foreach f {member1_add_files.tcl} {
    set p [get_property DIRECTORY [current_project]]/$f
    if {[file exists $p]} { file delete $p; puts "deleted old script $f" }
}

# 3. Add every file that is not in the project yet
proc m1_add {fs path} {
    if {![file exists $path]} {
        puts "MISSING (copy it into the repo first): $path"
        return
    }
    set name [file tail $path]
    set have [get_files -quiet -of_objects [get_filesets $fs] -filter "NAME =~ \"*/$name\""]
    if {[llength $have] == 0} {
        add_files -norecurse -fileset $fs $path
        puts "added $name"
    }
}

foreach f {uart_transmitter.v uart_receiver.v crc8_checksum.vh packet_sender.v packet_receiver.v
           link_monitor.v seven_segment_display.v link_test_top.v button_debouncer.v board_controls.v
           multiplayer_link.v ps2_host.v usb_mouse_keyboard.v player_controls.v bfs_pathfinder.v
           ai_bot.v opponent_select.v multiplayer_core.v jb_top.v My_Top_Module.v} {
    m1_add sources_1 $m1_srcs/sources_1/new/$f
}
foreach f {Basys3_Master.xdc link_test.xdc jb_top.xdc} {
    m1_add constrs_1 $m1_srcs/constrs_1/new/$f
}
foreach f {tb_uart.v tb_packet.v tb_board_controls.v tb_link_test_top.v tb_My_Top_Module.v
           tb_multiplayer_link.v ps2_device_model.v tb_usb_mouse_keyboard.v tb_player_controls.v
           tb_bfs_pathfinder.v tb_ai_bot.v tb_opponent_select.v tb_jb_top.v} {
    m1_add sim_1 $m1_srcs/sim_1/new/$f
}

# 4. Choosing the design: the top module and which constraint files are on
proc m1_constraints {enabled} {
    foreach f [get_files -quiet -of_objects [get_filesets constrs_1] -filter {FILE_TYPE == XDC}] {
        set_property IS_ENABLED [expr {[lsearch -exact $enabled [file tail $f]] >= 0}] $f
    }
}
proc use_team_top {} {
    set_property top My_Top_Module [get_filesets sources_1]
    m1_constraints {Basys3_Master.xdc}
    set_property top tb_My_Top_Module [get_filesets sim_1]
    update_compile_order -fileset sources_1
    puts "Top: My_Top_Module  (constraints: Basys3_Master.xdc)"
}
proc use_jb_top {} {
    set_property top jb_top [get_filesets sources_1]
    m1_constraints {jb_top.xdc}
    set_property top tb_jb_top [get_filesets sim_1]
    update_compile_order -fileset sources_1
    puts "Top: jb_top  (constraints: jb_top.xdc)"
}
proc use_link_test {} {
    set_property top link_test_top [get_filesets sources_1]
    m1_constraints {Basys3_Master.xdc link_test.xdc}
    set_property top tb_link_test_top [get_filesets sim_1]
    update_compile_order -fileset sources_1
    puts "Top: link_test_top  (constraints: Basys3_Master.xdc + link_test.xdc)"
}

set_property source_mgmt_mode All [current_project]
use_team_top
