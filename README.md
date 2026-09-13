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
file (`baseline.yml`) — the **source of truth**, the one place the
standard actually lives — and uses **Ansible**, a widely-used
open-source automation tool, to check every device against that
standard and fix only what's different.

## How it works

![baseline.yml is the source of truth. Ansible reads it and runs five steps in order, each its own playbook except step 1: write the standard (the baseline.yml file itself), check first (precheck.yml), show the plan (dry_run.yml), make the change (deploy.yml, the only step that touches a device), and check again (validate.yml then postcheck.yml).](docs/how-it-works.svg)

1. **Write down the standard.** One file (`baseline.yml`) lists what
   every device should have — banner text, time servers, where alerts
   and logs go.
2. **Check first** (`precheck.yml`). Before touching anything, it logs
   into a device and compares what's actually there to the standard —
   never assumes, always checks.
3. **Show the plan** (`dry_run.yml`). It lists exactly what would
   change, so a person can review it before anything actually happens.
4. **Make the change** (`deploy.yml`). Only the settings that are wrong
   get updated — anything already correct is left alone.
5. **Check again** (`validate.yml`, then `postcheck.yml`). Afterward,
   it checks the device one more time to confirm it now matches the
   standard, and keeps a copy of the result as a record.

Steps 2 through 5 are each their own small program — in Ansible,
called a **playbook** — so Ansible runs them one at a time, in order.
That's what makes them independent: each one can be reviewed, approved,
or stopped on its own — nothing happens by accident.

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
