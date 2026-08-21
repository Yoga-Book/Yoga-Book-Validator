# Attribution and references

Yoga Book Validator is a new, separately maintained validation project. Its
checks were informed by hands-on YB1-X91L bring-up and by diagnostic scripts
maintained with the Yoga Book kernel build branch:

- `scripts/yogabook/run-sof-test.sh`;
- `scripts/yogabook/test-sof-stability.sh`;
- `scripts/yogabook/test-sof-active-suspend.sh`;
- `scripts/yogabook/collect-pen-info.sh`.

Those scripts are not copied as deployment artifacts. The reusable validation
behavior was refactored behind a report-oriented interface, with the ALSA state
ordering fix retained. Destructive package-removal experiments and local logs
are intentionally excluded.

Related projects and upstream references:

- https://github.com/Yoga-Book/Halo-Keyboard
- https://github.com/Yoga-Book/Yoga-Book-Sensors
- https://github.com/jekhor/yogabook-linux
- https://gitlab.gnome.org/GNOME/mutter/-/work_items/4204
- https://thesofproject.github.io/

The project is licensed under GPL-2.0-or-later. Individual platform names and
trademarks belong to their respective owners.
