---
title: ATOMIC-GC
section: 8
header: System Administration
footer: atomic-upgrade
---

# NAME

atomic-gc — manage atomic-upgrade generations

# SYNOPSIS

**atomic-gc** [**-n**|**\--dry-run**] [*COUNT*]

**atomic-gc** **list**

**atomic-gc** **rm** [**-n**|**\--dry-run**] [**-y**|**\--yes**] *GEN_ID* [*GEN_ID*...]

# DESCRIPTION

**atomic-gc** manages generations created by **atomic-upgrade**(8). A
generation consists of a Btrfs subvolume (*root-TIMESTAMP*) and a matching
UKI file on the ESP (*arch-TIMESTAMP.efi*).

Without a subcommand, **atomic-gc** runs garbage collection: keeps the last
*COUNT* generations (default from **KEEP_GENERATIONS** in **atomic.conf**(5))
plus the currently booted one, and deletes the rest. After deletion, an orphan
sweep removes:

- Subvolumes that have no matching UKI on the ESP.
- UKI files that have no matching subvolume.

Orphan *home-\** subvolumes (created by **\--separate-home**) are **reported
but never auto-deleted** — they may contain user data. A message with the
manual deletion command is printed for each orphan.

If the ESP is not mounted during the orphan sweep, it is skipped with a
warning.

# SUBCOMMANDS

**(none)** [*COUNT*]
:   Run garbage collection. *COUNT* overrides the configured
    **KEEP_GENERATIONS** value. Requires root.

**list**
:   List all generations found on the ESP, newest first. The currently
    booted generation is marked with **(current)**. Does not require root.

**rm** *GEN_ID* [*GEN_ID*...]
:   Delete specific generation(s). Removes both the UKI file and the Btrfs
    subvolume. Refuses to delete the currently booted generation. Prompts
    for confirmation unless **-y** is given. Requires root.

# OPTIONS

**-n**, **\--dry-run**
:   Show what would be deleted without making changes.

**-y**, **\--yes**
:   Skip confirmation prompt (for **rm** subcommand only).

**-h**, **\--help**
:   Show usage summary and exit.

# EXIT STATUS

**0**
:   Success.

**1**
:   Error. Common causes: generation not found, attempted deletion of
    current generation, lock held by another instance.

# EXAMPLES

Garbage collect using configured default:

    sudo atomic-gc

Preview keeping only the last 2 generations:

    sudo atomic-gc --dry-run 2

List all generations:

    atomic-gc list

Delete a specific generation:

    sudo atomic-gc rm 20260217-143022

Delete multiple generations without confirmation:

    sudo atomic-gc rm -y 20260217-143022 20260216-235122

# SEE ALSO

**atomic-upgrade**(8), **atomic.conf**(5), **btrfs-subvolume**(8)
