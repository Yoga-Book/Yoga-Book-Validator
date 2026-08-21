# Contributing

Keep validation independent from implementation packages. Passive commands
must not modify the system. Active commands must be bounded, confirmed,
DMI-scoped, and restore every changed service or device state in traps.

New checks must emit the shared TSV schema and explain whether failure is
automated evidence, an unavailable prerequisite, or pending physical
acceptance. Adapt optional hardware expectations explicitly, especially SIM,
headset adapter, outdoor GNSS conditions, and camera privacy state.

Run `make test` and `git diff --check` before submitting a change.
