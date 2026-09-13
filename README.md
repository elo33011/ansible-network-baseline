# Ansible Network Baseline

A demo of how to keep a few basic settings consistent across a
company's network switches and routers — automatically, safely, and
only after being tested.

## What problem does this solve?

Every network switch needs some standard settings: a login warning
banner, the time server it syncs to, where it sends monitoring alerts,
and where it sends its logs. Normally someone configures each device by
hand, one at a time — slow, and easy to get wrong or miss on one
device.

This project writes down those standard settings *once*, in a single
file, and uses a tool called Ansible to check every device against that
standard and fix only what's different.

## How it works

1. **Write down the standard.** One file lists what every device
   should have — banner text, time servers, where alerts and logs go.
2. **Check first.** Before touching anything, it logs into a device and
   compares what's actually there to the standard — never assumes,
   always checks.
3. **Show the plan.** It lists exactly what would change, so a person
   can review it before anything actually happens.
4. **Make the change.** Only the settings that are wrong get updated —
   anything already correct is left alone.
5. **Check again.** Afterward, it checks the device one more time to
   confirm it now matches the standard, and keeps a copy of the result
   as a record.

Five separate steps means each one can be reviewed, approved, or
stopped on its own — nothing happens by accident.

## Tested before it's trusted

Nothing here is used on a real device until it's been tried out against
a practice device first — a stand-in that behaves like a real switch
but exists only for testing. Every change to this project is run
against that practice device automatically, so mistakes get caught
before they could ever reach a real one.

## Want the technical details?

See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for setup steps, exact
commands, how the pieces fit together, and how to point this at real
devices.
