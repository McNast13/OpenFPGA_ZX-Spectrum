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
100MHz+ `clk_sys`, far faster than the downstream 14-slot key scanner can
drain each entry, which risks filling the 7-deep FIFO during any sustained
key hold; the buffer controller silently drops writes while full, which
could in principle lose a real release event that landed while backlogged.
Disabling it removes that risk entirely at the cost of typematic repeat
(not needed for game controls, the priority here). Note: `tb_keyboard.sv`
below could not actually reproduce a stuck key from this mechanism in
simulation even with the repeat controller left enabled, so treat this as
a reasonable defensive simplification rather than a confirmed root cause -
see "Known limitation" below for the bug that simulation *did* confirm.

## `core_top.sv` integration: ps2_key must be edge-converted, not just registered

`usb_keyboard`'s `ps2_key[10]` ("strobe", from `key_mgr.sv`) is a *pulse* -
high for one cycle on a make/break event, then low again on its own - not a
level that flips and holds the way keyboard.sv (and the MiSTer convention
it follows) expects. `pressed`/`code` are also purely combinational,
continuously reflecting whichever of the 14 HID slots the round-robin
arbiter currently happens to be looking at. `core_top.sv` converts this
into a proper toggle by latching `pressed`/`code` and flipping a toggle bit
whenever strobe is high **and** the content differs from what was last
latched - not simply on strobe's rising edge, because when two keys change
in the *same* arbiter pass (e.g. releasing two held keys at once), both can
land on the arbiter's 1-cycle "empty slot" fast path back-to-back with no
gap between them, so strobe never drops back to 0 between the two events -
an edge-only detector misses the second one. Confirmed via
`tb_multikey.sv`.

## Fixed: releasing one of several held keys could drop another

If a HID host compacts the scancode slot array when one of several held
keys is released - the still-held key(s) shift to a lower slot index -
the slot it vacates still remembers its old occupant and emits a stale
break for that code on this same scan pass. Since `keyboard.sv`'s `keys[][]`
matrix is indexed by PS/2 code, not by which HID slot reported it, that
stale break could race with and overwrite the still-held key's press state
if it arrived after the new slot's press event. Confirmed on real hardware
(two directional keys held - release one, the other would drop) and via
simulation (`tb_compaction_fix.sv`).

Fixed in `core_top.sv`, not in these vendored files: a "live" snapshot of
currently-held PS/2 codes is independently re-translated straight from
`usb_kbd`'s own `usb_kb_mod`/`usb_kb_sc1..6` outputs (which it already
computes internally for its slot-tracking path) via one extra `hid2ps2_mod`
and six extra `hid2ps2_key` instances - bypassing `kb_fifo`/`key_arbiter`/
`key_mgr` entirely, so it can't inherit their slot-indexing problem. A
release event is only let through if its code is *not* found anywhere in
that live snapshot; if it is, the release is stale (the key just moved
slots) and gets suppressed. Presses always pass through unchanged, so
this can only ever hold a release back, never fabricate or drop a press.

## Running the testbenches

`tb_keyboard.sv` (single key, incl. a long hold), `tb_multikey.sv` (two keys
at once), `tb_modifier.sv` (Shift+key combos, both press orders),
`tb_compaction_fix.sv` (the slot-compaction scenario above, a sanity check
that the fix doesn't suppress genuine releases, and the cascading-stuck
regression from the "ps2_key_usb_prev" fix), `tb_mash.sv` (all 8 pairs of
the QAOP+Space beat-em-up scheme, holding one key while rapidly mashing
another) and `tb_mash3.sv` (three keys at once - hold two, mash a third)
are self-contained Icarus Verilog testbenches instantiating this bridge
exactly as `core_top.sv` wires it, to verify press/hold/release behaviour
without real hardware. All six pass as of the fixes documented above. They
can't be run directly against these files with Icarus (`brew install icarus-verilog`)
as-is: Icarus's SystemVerilog support has gaps that Quartus doesn't share
(enum assignment needs an explicit cast, forward-referenced declarations
need reordering, a `logic` port can't have both an initializer and a
continuous assign) - none of these are real bugs, Quartus has built this
design cleanly multiple times in CI. Make Icarus-only patched copies of
`key_arbiter.sv`, `key_mgr.sv` and `usb_keyboard.sv` to work around them
(reorder `data_valid`/`cycle_counter` above their first use, wrap the two
`next_state[i] = ... ? ... : ...;` assignments in `KeyState'(...)`, drop
the `= 11'h0` initializer on `usb_keyboard`'s `ps2_key` port), then:

```
iverilog -g2012 -o tb.vvp tb_keyboard.sv usb_keyboard.sv apf2hid.sv \
  hid2ps2_key.sv hid2ps2_mod.sv kb_fifo.sv key_arbiter.sv key_mgr.sv \
  ../keyboard.sv
vvp tb.vvp
```
