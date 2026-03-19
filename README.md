# Removed: atomic-env and ephemeral generations

## What it was

Named environments (`atomic-env create kde -- pacman -S plasma-meta`) and
one-shot ephemeral generations (`atomic-upgrade --ephemeral`) with isolated
`/home` subvolumes per environment. The idea: boot into a completely separate
system state without polluting your main home directory.

Implemented over a single session (18 commits, ~2 hours), debugged to working
state, then removed.

## What it added

- `atomic-env` (780 lines) — create/update/delete/boot/list named environments
- `--ephemeral` flag for `atomic-upgrade` — one-shot generations auto-cleaned by GC
- Per-environment `/home` subvolumes with optional `--copy-files`
- `fstab.py` extension for `/home` subvol rewriting
- Home skeleton population (`populate_home_skeleton`)
- GC awareness of `env-*`, `ephemeral-home-*`, and `env-*-pre-update` subvolumes
- Rollback logic for failed creates and updates (6 global state variables, trap handler)
- Shell completions for `atomic-env` and `atomic-upgrade` (zsh + bash)
- Guard graceful degradation when `common.sh` fails to load

Total: ~1200 new lines across 12 files.

## Why it was removed

### No real use case

The motivating scenario — maintaining parallel system configurations with
isolated homes, switching between them — never matched an actual workflow.
The code was built around an idea, not a need.

### Accidental complexity from a flat naming convention

Environments stored everything as flat subvolumes in the btrfs top-level:

```
env-NAME            ← root
env-NAME-home       ← home
env-NAME-pre-update ← backup during update
ephemeral-home-ID   ← ephemeral home
```

No metadata file, no nested structure. Every piece of code that enumerates
subvolumes had to solve the same disambiguation problem: is `env-foo-home`
the home subvolume of environment `foo`, or the root subvolume of an
environment named `foo-home`?

This produced ~400 lines of defensive checks duplicated across `do_list`,
`do_delete`, GC orphan sweep, and completion scripts. The reserved-suffix
validation (`-(home|pre-update)$` rejected in names) existed solely to
prevent collisions that a structured layout would have made impossible.

### Update was unnecessary

`atomic-env update` created a pre-update backup snapshot, ran a chroot
command, rebuilt the UKI, and rolled back on failure — a second independent
rollback mechanism alongside the one in `atomic-upgrade`. The same result
is achievable by deleting and recreating the environment (the home subvolume
persists independently).

### Boot management duplicated existing tools

`atomic-env boot --default NAME` wrapped `bootctl set-default` with
environment validation. `atomic-env boot --reset` removed a line from
`loader.conf`. Both are one-liners without the wrapper.

### State spread across six locations

An environment's existence was tracked by: btrfs subvolume presence, home
subvolume presence, UKI file on ESP, fstab root entry, fstab home entry,
and loader.conf default. No single source of truth. Every operation checked
multiple locations, and any desynchronization produced orphans that GC had
to sweep.

### GC tripled in complexity

Before: enumerate generations, keep N newest, delete the rest, sweep orphans
(two patterns: `root-*` without UKI, UKI without `root-*`).

After: three phases (ephemeral cleanup, standard keep/delete skipping `env-*`,
orphan sweep for four patterns with disambiguation). The orphan sweep alone
handled `root-*`, `ephemeral-home-*`, `env-*-home`, and `env-*-pre-update`,
each with safety checks against false positives.

### Bash is the wrong tool for transactional operations

`do_create` is an 8-step transaction (snapshot → home subvol → mount → bind
ESP → bind pacman cache → update fstab → chroot → build UKI) with 10+ failure
points and rollback via trap handler reading 6 global mutable variables.
It works, but every modification requires reasoning about cleanup paths that
the language provides no structure for.

## What was kept

The guard graceful degradation fix (`atomic-guard` falling back to inline
AUR helper detection when `common.sh` fails to load) was cherry-picked as
an independent bugfix.

## What replaced it

The isolated-home requirement is addressed by `--separate-home` in
`atomic-upgrade`: ~40 lines that create a `home-TAG` subvolume and rewrite
`/home` in the snapshot's fstab. No separate tool, no update mechanism, no
additional cleanup paths. The home subvolume persists across regenerations
with the same tag and is listed (not auto-deleted) by GC orphan sweep.

## Code

Preserved in branch `archive/env-ephemeral` at commit `f31c483`.
