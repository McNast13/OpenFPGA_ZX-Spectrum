# USB Keyboard Bridge

Converts the Analogue Pocket openFPGA "docked keyboard" controller-bus report
(`cont3_key` / `cont3_joy` / `cont3_trig`) into a standard MiSTer-style
`ps2_key[10:0]` strobe, so a real USB keyboard connected via the Analogue Dock
can drive `core/keyboard.sv` exactly as a PS/2 keyboard would on MiSTer.

These files are vendored, unmodified, from the OpenGateware project's
`computer-msx` core (`platform/pocket/interface/keyboard/`), where each file
carries its own `SPDX-License-Identifier: MIT` header:

https://github.com/opengateware/computer-msx

Copyright (c) 2023, Marcus Andrade <marcus@opengateware.org>
Copyright (c) 2023, Jacob Boline <mail@jboline.me>

`key_ctl.sv` from the upstream directory was not vendored here as it is not
used by `usb_keyboard.sv`.
