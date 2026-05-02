---
title: ATOMIC.CONF
section: 5
header: File Formats
footer: atomic-upgrade
---

# NAME

atomic.conf — configuration file for atomic-upgrade

# SYNOPSIS

*/etc/atomic.conf*

# DESCRIPTION

**atomic.conf** is the configuration file for **atomic-upgrade**(8),
**atomic-gc**(8), **atomic-rebuild-uki**, **atomic-guard**, and the
pacman wrapper. It is read on every invocation. Changes take effect
immediately without restarting any service.

The file format is *KEY=VALUE*, one per line. Comments begin with **#**.
Inline comments are supported when preceded by a space (e.g.,
**KEEP_GENERATIONS=3 # keep three**). Values may optionally be enclosed in
single or double quotes, which are stripped during parsing.

**Note:** inline comment detection splits on the first ` #` (space + hash)
occurrence. Values containing a literal ` #` sequence will be truncated at
that point. This does not affect typical paths or kernel parameters.

Only allowed keys are accepted. Unknown keys produce a warning on stderr
and are ignored. The file must be owned by root (uid 0) when at
`/etc/atomic.conf`; otherwise it is rejected entirely.

# OPTIONS

**BTRFS_MOUNT**
:   Mount point for the Btrfs top-level subvolume (subvolid=5) during
    operations. Default: */run/atomic/temp_root*.

**NEW_ROOT**
:   Mount point for the new snapshot during chroot. Must differ from
    **BTRFS_MOUNT**. Default: */run/atomic/newroot*.

**ESP**
:   EFI System Partition mount point. Automatically mounted if not already
    mounted. Default: */efi*.

**KEEP_GENERATIONS**
:   Number of non-current generations to keep during garbage collection.
    Must be an integer >= 1. Default: **3**.

**MAPPER_NAME**
:   dm-crypt mapper name used as a fallback when auto-detection of the root
    block device fails. Default: **root_crypt**.

**KERNEL_PKG**
:   Name of the kernel package. Determines which *vmlinuz* and *initramfs*
    files are used for UKI builds. Common values: **linux**, **linux-lts**,
    **linux-zen**. Default: **linux**.

**KERNEL_PARAMS**
:   Kernel command line parameters appended after the auto-detected root
    device arguments. Default: **rw slab_nomerge init_on_alloc=1
    page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on
    debugfs=off**.

**CHROOT_COMMAND**
:   Default command to run in the snapshot chroot, overriding the built-in
    default of **pacman -Syu**. Command-line **-- CHROOT_COMMAND...** takes priority
    over this setting. Arguments with spaces are supported via proper
    shell-style quote handling. Default: */usr/bin/pacman -Syu*.

**SBCTL_SIGN**
:   Enable UKI signing with **sbctl**(8) for Secure Boot. Set to **1** to
    enable, **0** to disable. When disabled, UKI files are built unsigned.
    Default: **0**.

**UPGRADE_GUARD**
:   Enable the upgrade guard (pacman hook and wrapper). Set to **1** to
    block direct **pacman -Syu**, **0** to allow it. Default: **1**.

**HOME_COPY_FILES**
:   Space-separated list of files to copy from */home/<user>/* into isolated
    home subvolumes created with **\--separate-home**. Paths are relative to
    the user's home directory. The **\--copy-files** flag on the command line
    overrides this value per invocation. Paths with spaces are not supported.
    Default: *(empty)*.

# SECURITY

The configuration file must be owned by root when at `/etc/atomic.conf`.
If the file is owned by another user, it is rejected and no values are loaded.

Only the keys listed above are accepted. Attempts to set arbitrary shell
variables (e.g., **PATH**, **LD_PRELOAD**) via the config file are silently
ignored. The file is parsed line-by-line with a safe parser — it is never
sourced or evaluated as shell code.

# EXAMPLES

Minimal configuration (all defaults):

    # /etc/atomic.conf
    # Empty — all defaults apply

Custom ESP and kernel:

    ESP=/boot/efi
    KERNEL_PKG=linux-zen

Enable Secure Boot signing:

    SBCTL_SIGN=1

LUKS with TPM2 auto-unlock:

    KERNEL_PARAMS=rd.luks.options=tpm2-device=auto rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off

Disable upgrade guard:

    UPGRADE_GUARD=0

Keep more generations:

    KEEP_GENERATIONS=5

Default files for isolated homes:

    HOME_COPY_FILES=".bashrc .bash_profile .ssh .gnupg .gitconfig"

# SEE ALSO

**atomic-upgrade**(8), **atomic-gc**(8), **sbctl**(8), **pacman.conf**(5)
