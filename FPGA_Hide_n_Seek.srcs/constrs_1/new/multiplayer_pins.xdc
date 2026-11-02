## Extra pins for My_Top_Module, used TOGETHER with Basys3_Master.xdc.
## (Basys3_Master.xdc has the clock, buttons, switches, LEDs and the OLED on JB.)
## Keep link_test.xdc and jb_top.xdc disabled while My_Top_Module is the top.

## USB mouse or keyboard (Basys3 USB HID port, PS/2 signals)
set_property -dict { PACKAGE_PIN C17  IOSTANDARD LVCMOS33 PULLUP true } [get_ports PS2Clk]
set_property -dict { PACKAGE_PIN B17  IOSTANDARD LVCMOS33 PULLUP true } [get_ports PS2Data]

## Board-to-board link on Pmod JA: JA1 = link_tx, JA2 = link_rx, JA5 = GND
set_property -dict { PACKAGE_PIN J1   IOSTANDARD LVCMOS33 } [get_ports link_tx]
set_property -dict { PACKAGE_PIN L2   IOSTANDARD LVCMOS33 } [get_ports link_rx]
set_property PULLUP true [get_ports link_rx]

## 7-segment display
set_property -dict { PACKAGE_PIN W7   IOSTANDARD LVCMOS33 } [get_ports {seg[0]}]
set_property -dict { PACKAGE_PIN W6   IOSTANDARD LVCMOS33 } [get_ports {seg[1]}]
set_property -dict { PACKAGE_PIN U8   IOSTANDARD LVCMOS33 } [get_ports {seg[2]}]
set_property -dict { PACKAGE_PIN V8   IOSTANDARD LVCMOS33 } [get_ports {seg[3]}]
set_property -dict { PACKAGE_PIN U5   IOSTANDARD LVCMOS33 } [get_ports {seg[4]}]
set_property -dict { PACKAGE_PIN V5   IOSTANDARD LVCMOS33 } [get_ports {seg[5]}]
set_property -dict { PACKAGE_PIN U7   IOSTANDARD LVCMOS33 } [get_ports {seg[6]}]
set_property -dict { PACKAGE_PIN V7   IOSTANDARD LVCMOS33 } [get_ports dp]
set_property -dict { PACKAGE_PIN U2   IOSTANDARD LVCMOS33 } [get_ports {an[0]}]
set_property -dict { PACKAGE_PIN U4   IOSTANDARD LVCMOS33 } [get_ports {an[1]}]
set_property -dict { PACKAGE_PIN V4   IOSTANDARD LVCMOS33 } [get_ports {an[2]}]
set_property -dict { PACKAGE_PIN W4   IOSTANDARD LVCMOS33 } [get_ports {an[3]}]
