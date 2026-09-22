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

## Local modification: `hid2ps2_key`/`hid2ps2_mod` clocked on the rising edge

Upstream clocks all seven ROM-lookup instances in `usb_keyboard.sv` (six
`hid2ps2_key` + one `hid2ps2_mod`, and the equivalent "live snapshot"
instances added in `core_top.sv` for the compaction fix below) on the
*falling* edge of `clk`, while every other clock in this design - including
the posedge-clocked stage that reads their output (`kb_fifo`) - is on the
rising edge. That gives a negedge-launched signal only a HALF clock period
to reach the next posedge before it's captured, not a full one. CI's
timing report named exactly this ("Launch Clock ... INVERTED" on a
`hid2ps2_key` instance) as the worst offender after the `ps2_key` pipeline-
register fix below, and it was left unresolved at the time pending
confirmation it caused a real symptom. It did: a hardware report of keys
sticking after sustained rapid play (figure-8 movement + occasional
punches in 128K BASIC and in-game), recoverable exactly once by pressing
an unrelated modifier key before re-sticking - the signature of occasional
marginal-timing metastability, not a logic bug (a logic bug wouldn't be
"fixed" by an unrelated keypress, or need sustained activity to first
appear). Changed all seven instances (both here and in `core_top.sv`) to
the rising edge, matching everything downstream, for a full clock period
of margin instead of half.

That fix removed that specific path from CI's timing report entirely, but
didn't fully close clk_sys setup timing on its own - the device is 93%
ALM-full and was already marginal (-0.15ns) before any keyboard work
existed. The *next* worst path ran from inside `kb_fifo` all the way to
`core_top.sv`'s own `ps2_key_latched` register - the one register
`keyboard.sv` actually reads pressed/code from, so occasional
metastability landing there is about as consequential a place as this
design has. Two register-level attempts followed, one that helped and one
that didn't:

- Adding a plain pipeline register on `usb_kbd`'s `ps2_key` output
  (`ps2_key_usb_r`) *did* measurably improve the timing report (TNS
  -127ns -> -10ns), but wasn't enough on its own - a hardware report of
  sticky keys, still present, confirmed it.
- Registering `key_mgr.sv`'s output one level deeper (turning its plain
  `assign key_code = ...` into a clocked register) looked like the same
  fix applied earlier and one hop closer to the source, but *regressed*
  the timing report (TNS -10ns -> -67ns). At 92%+ ALM-full, register
  insertion is not reliably monotonic - the placer can end up worse off
  even though the logical path is shorter, because the extra register
  has to land *somewhere* in an already-congested fabric. This was
  reverted before shipping (`git revert` of that commit) once the CI
  timing report was checked and the regression confirmed - do not
  re-attempt this specific change without re-verifying against a fresh
  timing report, not just "shorter combinational path = better" logic.

Both were still chasing timing path-by-path in the clk_sys domain, which
this design has limited headroom for. The section below replaced this
approach entirely rather than continuing to add clk_sys pipeline stages.

## The USB keyboard bridge runs on `clk_74a`, not `clk_sys`

Chasing individual clk_sys paths one at a time was fighting the actual
constraint: this device is 92-93% ALM-full, and clk_sys itself was
already marginal before any keyboard code existed, so every register
added to buy back timing has to land somewhere in an already-congested
placement - sometimes it helps (the `ps2_key_usb_r` pipeline register
above), sometimes it measurably doesn't (the `key_mgr.sv` attempt above).
None of this logic needs to run anywhere near clk_sys speed in the first
place - keyboard events are human-speed. So instead of continuing to
chase paths, the whole `usb_keyboard` instantiation, the seven "live
snapshot" `hid2ps2_key`/`hid2ps2_mod` instances, and all the toggle/
latch/suppression logic between them now run on `clk_74a` (13.468ns
period vs clk_sys's 8.928ns) - a real, independent clock this design
already declares and constrains as asynchronous to clk_sys in
`core_constraints.sdc` via `set_clock_groups`, so this needed no new SDC
work, just correct clock-domain-crossing at the boundary:

- `cont3_key`/`cont3_joy`/`cont3_trig` (APF bridge inputs, native to
  neither clock) are synchronized into clk_74a with `synch_3` before use,
  the same treatment `cont1_key` already gets elsewhere in `core_top.sv`
  - without it a bus sampled mid-transition can tear, and apf2hid's own
  downstream pipeline doesn't fix that since it just re-registers
  whatever value it was handed.
- The toggle/latch/suppression logic that used to run on clk_sys now runs
  entirely on clk_74a instead, staging content a full clk_74a cycle
  before flipping the toggle bit that signals it, so a single-bit
  `synch_3` synchronizer can safely carry the toggle into clk_sys without
  the risk of sampling multi-bit content mid-change (a toggle bit can't
  tear; sampling `ps2_key_latched_74a` directly from clk_sys without this
  staging could).
- A depth-2 queue (`ps2_q0`/`ps2_q1`/`ps2_qcount`) holds pending events
  rather than a single "pending toggle" flag, because releasing two held
  keys at once (or a direction change with slot compaction) can produce
  two real events one clk_74a cycle apart, and a single-flag design's
  `if (pending) ... else if (new event) ...` structure silently dropped
  the second one when it landed on the exact cycle the first one's
  toggle was flipping.
- Draining that queue is gated by a request/ack handshake
  (`ps2_ack_74a`, itself `ps2_toggle_sync` echoed back into clk_74a
  through a second `synch_3`), not just "one cycle per queued entry".
  Without it, two back-to-back drains produce a toggle pulse only about
  27ns wide - shorter than clk_sys's own 4-stage `synch_3` detection
  latency at this clock's relative speed - so the synchronizer can merge
  both transitions into one and only ever report the *later* event's
  content, silently losing the earlier one (confirmed via a dedicated
  trace testbench: a real key's release toggle flip never produced its
  own rise/fall on the clk_sys side at all when a second event followed
  it too closely). The handshake makes the drain side wait for
  confirmation that clk_sys has caught up before flipping the toggle
  again, so back-to-back events are serialized correctly instead of
  racing the synchronizer's own latency.

All six testbenches below reproduce this exactly (two independent
`always` clock generators, `clk_sys` and `clk_74a`, at their real
periods) and pass with this design; `tb_compaction_fix.sv` in particular
is what caught both bugs above during development - first the dropped-
event bug (as `hw_key_data` never showing a key released), then, after
the queue fix alone didn't change the result, the fast-pulse merge bug
(found by tracing `ps2_toggle_74a`/`ps2_ack_74a` cycle-by-cycle around
the failure and noticing the same content was reaching clk_sys twice
while the first event's toggle transition was never independently
observed there at all).

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
seen (`ps2_key_usb_prev_74a`, the raw previous-cycle value - see "The USB
keyboard bridge runs on clk_74a" above for why not the output latch or a
separate "last seen" register) - not simply on strobe's rising edge,
because when two keys change in the *same* arbiter pass (e.g. releasing
two held keys at once), both can land on the arbiter's 1-cycle "empty
slot" fast path back-to-back with no gap between them, so strobe never
drops back to 0 between the two events - an edge-only detector misses the
second one. Confirmed via `tb_multikey.sv`. The queue and handshake
described above exist specifically so that catching both back-to-back
events like this also gets both of them all the way to clk_sys correctly,
not just detected on the clk_74a side.

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
exactly as `core_top.sv` wires it - two independent clock generators
(`clk_sys` at 8.928ns, `clk_74a` at 13.468ns) plus `common.v`'s `synch_3`
for the clock-domain crossings, matching the real design - to verify
press/hold/release behaviour without real hardware. All six pass as of
the fixes documented above. They can't be run directly against these
files with Icarus (`brew install icarus-verilog`) as-is: Icarus's
SystemVerilog support has gaps that Quartus doesn't share (enum
assignment needs an explicit cast, forward-referenced declarations need
reordering, a `logic` port can't have both an initializer and a
continuous assign) - none of these are real bugs, Quartus has built this
design cleanly multiple times in CI. Make Icarus-only patched copies of
`key_arbiter.sv`, `key_mgr.sv` and `usb_keyboard.sv` to work around them
(reorder `data_valid`/`cycle_counter` above their first use, wrap the two
`next_state[i] = ... ? ... : ...;` assignments in `KeyState'(...)`, drop
the `= 11'h0` initializer on `usb_keyboard`'s `ps2_key` port), then:

```
iverilog -g2012 -o tb.vvp tb_keyboard.sv usb_keyboard.sv apf2hid.sv \
  hid2ps2_key.sv hid2ps2_mod.sv kb_fifo.sv key_arbiter.sv key_mgr.sv \
  ../keyboard.sv ../../apf/common.v
vvp tb.vvp
```
