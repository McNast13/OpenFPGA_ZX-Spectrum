# USB Keyboard Bridge

Converts the Analogue Pocket openFPGA "docked keyboard" controller-bus report
(`cont3_key` / `cont3_joy` / `cont3_trig`) into a standard MiSTer-style
`ps2_key[10:0]` strobe, so a real USB keyboard connected via the Analogue Dock
can drive `core/keyboard.sv` exactly as a PS/2 keyboard would on MiSTer.

These files are vendored from the OpenGateware project's `computer-msx` core
(`platform/pocket/interface/keyboard/`), where each file carries its own
`SPDX-License-Identifier: MIT` header:

https://github.com/opengateware/computer-msx

Copyright (c) 2023, Marcus Andrade <marcus@opengateware.org>
Copyright (c) 2023, Jacob Boline <mail@jboline.me>

`key_ctl.sv` from the upstream directory was not vendored here as it is not
used by `usb_keyboard.sv`.

## Local modification: `kb_fifo.sv`'s key-repeat controller is disabled

Everything is otherwise unmodified from upstream. `kb_fifo.sv`'s "Key Repeat
Controller" block synthesizes typematic auto-repeat by periodically
re-queuing the current HID report. On this core it runs at the full
100MHz+ `clk_sys`, so it re-queued far faster than the downstream 14-slot
key scanner could drain each entry, filling the 7-deep FIFO during any
sustained key hold. `kb_fifo.sv`'s buffer controller silently drops writes
while full, so a real key-release landing while the FIFO was backlogged
got lost - the key would then read as held until an unrelated future
keypress happened to reveal the true state ("sticky" keys, worse the
longer a key was held). See the comment at that block for detail.
