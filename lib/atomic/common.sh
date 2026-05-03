#!/bin/bash
# /usr/lib/atomic/common.sh
#
# Shared functions and configuration for the atomic-upgrade system.
# Sourced by: atomic-upgrade, atomic-gc, atomic-rebuild-uki, atomic-guard

_ATOMIC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Project version ────────────────────────────────────────────────

VERSION="0.2.1"

# ── Defaults (overridable via /etc/atomic.conf) ─────────────────────
BTRFS_MOUNT="/run/atomic/temp_root"
NEW_ROOT="/run/atomic/newroot"
ESP="/efi"
KEEP_GENERATIONS=3
MAPPER_NAME="root_crypt"
KERNEL_PKG="linux"
LOCK_DIR="/run/atomic"
LOCK_FILE="${LOCK_FILE:-${LOCK_DIR}/atomic-upgrade.lock}"
SBCTL_SIGN=0
UPGRADE_GUARD=1
# Files to copy from /home/<user>/ into isolated homes (space-separated)
HOME_COPY_FILES=""
# Kernel security parameters
KERNEL_PARAMS="rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"
# Default chroot command (overridden by config or CLI -- CHROOT_COMMAND...)
CHROOT_COMMAND="/usr/bin/pacman -Syu"

# ── Config loading (delegates to Python for proper quote handling) ───────

CONFIG_FILE="${CONFIG_FILE:-/etc/atomic.conf}"

load_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0

    local shell_output config_err
    if ! shell_output=$(CONFIG_FILE="${CONFIG_FILE}" python3 "${_ATOMIC_LIB_DIR}/config.py" shell 2>/dev/null); then
        config_err=$(CONFIG_FILE="${CONFIG_FILE}" python3 "${_ATOMIC_LIB_DIR}/config.py" shell 2>&1) || true
        echo "ERROR: Failed to parse config with config.py" >&2
        echo "ERROR: Details: ${config_err:-unknown}" >&2
        return 1
    fi

    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        printf -v "$key" '%s' "$value"
    done <<< "$shell_output"
}

# ── Auto-initialization ──────────────────────────────────────────────
# Skipped when _ATOMIC_NO_INIT is set (e.g. in test harnesses that
# source common.sh only for function definitions and defaults).

if [[ -z "${_ATOMIC_NO_INIT:-}" ]]; then
    load_config
fi

# ── Validation ──────────────────────────────────────────────────────

validate_config() {
    if ! mountpoint -q "$ESP" 2>/dev/null; then
        mount "$ESP" 2>/dev/null || {
            echo "ERROR: ESP not mounted: $ESP" >&2
            return 1
        }
    fi
    get_root_device >/dev/null || return 1
    [[ "$KEEP_GENERATIONS" =~ ^[0-9]+$ ]] || { echo "ERROR: Invalid KEEP_GENERATIONS" >&2; return 1; }
    [[ "$KEEP_GENERATIONS" -ge 1 ]] || { echo "ERROR: KEEP_GENERATIONS must be >= 1" >&2; return 1; }
    if [[ "$NEW_ROOT" == "$BTRFS_MOUNT" ]]; then
        echo "ERROR: NEW_ROOT and BTRFS_MOUNT must be different paths" >&2
        return 1
    fi
    return 0
}

# ── Dependency check ────────────────────────────────────────────────

check_dependencies() {
    local missing=()
    for cmd in btrfs ukify findmnt chroot unshare python3; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done

    if [[ "$SBCTL_SIGN" -eq 1 ]]; then
        command -v sbctl >/dev/null || missing+=("sbctl")
    fi

    local root_type
    root_type=$(python3 -c "
import json, importlib.util, sys
spec = importlib.util.spec_from_file_location('rootdev', '${_ATOMIC_LIB_DIR}/rootdev.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    result = mod.detect_root()
    print(result.get('type', '') if isinstance(result, dict) else '')
except Exception:
    print('')
" 2>/dev/null)
    if [[ "$root_type" == *luks* ]]; then
        command -v cryptsetup >/dev/null || missing+=("cryptsetup")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing commands: ${missing[*]}" >&2
        return 1
    fi
    # Verify python helper modules exist
    for helper in "${_ATOMIC_LIB_DIR}/fstab.py" "${_ATOMIC_LIB_DIR}/rootdev.py"; do
        [[ -f "$helper" ]] || {
            echo "ERROR: Missing helper: $helper" >&2
            return 1
        }
    done
}

# ── Chroot unmount helper (module-level, called by chroot_snapshot) ──

_chroot_umount() {
    local root="$1"
    umount "${root}${LOCK_DIR}" 2>/dev/null
    umount "${root}/tmp" 2>/dev/null
    umount "${root}/run" 2>/dev/null
    umount "${root}/dev/shm" 2>/dev/null
    umount "${root}/dev/pts" 2>/dev/null
    umount "${root}/dev" 2>/dev/null
    umount "${root}/sys/firmware/efi/efivars" 2>/dev/null
    umount "${root}/sys" 2>/dev/null
}

# ── Snapshot chroot (replaces arch-chroot dependency) ────────────

chroot_snapshot() {
    local root="$1"; shift
    local rc=0
    local resolv_link=""

    mount -t sysfs sys "${root}/sys" -o nosuid,noexec,nodev,ro || return 1
    if [[ -d "${root}/sys/firmware/efi/efivars" ]]; then
        mount -t efivarfs efivarfs "${root}/sys/firmware/efi/efivars" \
            -o nosuid,noexec,nodev 2>/dev/null || true
    fi
    mount -t devtmpfs udev "${root}/dev" -o mode=0755,nosuid || { _chroot_umount "$root"; return 1; }
    mount -t devpts devpts "${root}/dev/pts" \
        -o mode=0620,gid=5,nosuid,noexec || { _chroot_umount "$root"; return 1; }
    mount -t tmpfs shm "${root}/dev/shm" -o mode=1777,nosuid,nodev || { _chroot_umount "$root"; return 1; }
    mount -t tmpfs run "${root}/run" -o nosuid,nodev,mode=0755 || { _chroot_umount "$root"; return 1; }
    mount -t tmpfs tmp "${root}/tmp" \
        -o mode=1777,strictatime,nodev,nosuid || { _chroot_umount "$root"; return 1; }

    # Expose host lock directory for atomic-guard verification
    if [[ -d "${LOCK_DIR}" ]]; then
        mkdir -p "${root}${LOCK_DIR}"
        mount --bind "${LOCK_DIR}" "${root}${LOCK_DIR}" || true
    fi

    # DNS — handle symlinks
    local resolv_target="${root}/etc/resolv.conf"
    if [[ -e /etc/resolv.conf ]]; then
        if [[ -L "$resolv_target" ]]; then
            resolv_link=$(readlink "$resolv_target")
            rm -f "$resolv_target"
            touch "$resolv_target"
            mount --bind /etc/resolv.conf "$resolv_target" || true
        elif [[ -e "$resolv_target" ]]; then
            mount --bind /etc/resolv.conf "$resolv_target" || true
        fi
    fi

    unshare --fork --pid --kill-child \
        --mount --mount-proc="${root}/proc" \
        chroot "${root}" \
        /usr/bin/env SHELL=/bin/bash SYSTEMD_IN_CHROOT=1 ATOMIC_UPGRADE=1 \
        "$@" || rc=$?

    # Teardown — reverse order
    umount "$resolv_target" 2>/dev/null
    if [[ -n "$resolv_link" ]]; then
        rm -f "$resolv_target"
        ln -sf "$resolv_link" "$resolv_target"
    fi
    _chroot_umount "$root"
    umount "${root}/proc" 2>/dev/null

    return $rc
}

# ── Locking ─────────────────────────────────────────────────────────

acquire_lock() {
    [[ -d "$LOCK_DIR" ]] || mkdir -p "$LOCK_DIR"

    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        echo "ERROR: Another atomic operation is running" >&2
        exit 1
    fi
    export LOCK_FD
}

# ── AUR helper detection ────────────────────────────────────────

is_child_of_aur_helper() {
    local pid=$$
    while [[ $pid -ne 1 ]]; do
        local comm
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || break
        case "$comm" in
            yay|paru|pikaur|aura) return 0 ;;
        esac
        pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null) || break
    done
    return 1
}

# ── Secure Boot signing helpers ──────────────────────────────────

sign_uki() {
    local uki_path="$1"
    if [[ "$SBCTL_SIGN" -eq 1 ]]; then
        echo ":: Signing UKI for Secure Boot..."
        sbctl sign "$uki_path" || { echo "ERROR: Signing failed" >&2; return 1; }
    else
        echo ":: Skipping Secure Boot signing (SBCTL_SIGN=0)"
    fi
}

verify_uki() {
    local uki_path="$1"
    if [[ "$SBCTL_SIGN" -eq 1 ]]; then
        echo ":: Verifying signature..."
        sbctl verify "$uki_path" || echo "WARN: Signature verification failed, check manually" >&2
    fi
}

# ── fstab update (delegates to Python for safety) ──────────────────

update_fstab() {
    python3 "${_ATOMIC_LIB_DIR}/fstab.py" "$@"
}

# ── fstab /home update ──────────────────────────────────────────
# Updates the /home mount entry's subvol= to point to a new subvolume.
# Args: $1 = fstab path, $2 = new home subvolume name

update_fstab_home() {
    python3 "${_ATOMIC_LIB_DIR}/fstab.py" home "$@"
}

# ── Home skeleton population ────────────────────────────────────
# Creates user directories in a new home subvolume with correct
# ownership/permissions. Optionally copies specific files.
#
# Args:
#   $1 = target home path (e.g. ${BTRFS_MOUNT}/home-kde)
#   $2 = space-separated list of files to copy (optional, falls back to HOME_COPY_FILES)
#
# Note: paths with spaces are not supported.

populate_home_skeleton() {
    local target_home="$1"
    local copy_files="${2:-${HOME_COPY_FILES}}"

    [[ -d "/home" ]] || return 0

    local user_dir username target uid
    for user_dir in /home/*/; do
        [[ -d "$user_dir" ]] || continue
        username=$(basename "$user_dir")
        # Skip non-user directories (lost+found, system dirs)
        uid=$(id -u "$username" 2>/dev/null) || continue
        [[ $uid -ge 1000 ]] || continue
        target="${target_home}/${username}"
        mkdir -p "$target"
        chown --reference="$user_dir" "$target" 2>/dev/null || true
        chmod --reference="$user_dir" "$target" 2>/dev/null || true

        if [[ -n "$copy_files" ]]; then
            local file_rel
            # Disable globbing to prevent pattern expansion in unquoted $copy_files
            local _had_noglob=false
            shopt -q noglob && _had_noglob=true
            set -f
            for file_rel in $copy_files; do
                # Sanitize: no absolute paths, no path traversal
                case "$file_rel" in
                    /*|..|../*|*/../*|*/..)
                        echo "WARN: Skipping unsafe path: ${file_rel}" >&2
                        continue
                        ;;
                esac

                local src="${user_dir}${file_rel}"
                local dst="${target}/${file_rel}"

                if [[ -e "$src" ]]; then
                    local dst_dir
                    dst_dir=$(dirname "$dst")
                    if [[ ! -d "$dst_dir" ]]; then
                        mkdir -p "$dst_dir"
                        local src_dir
                        src_dir=$(dirname "$src")
                        chown --reference="$src_dir" "$dst_dir" 2>/dev/null || true
                        chmod --reference="$src_dir" "$dst_dir" 2>/dev/null || true
                    fi
                    cp -a "$src" "$dst" 2>/dev/null || {
                        echo "WARN: Failed to copy: ${file_rel}" >&2
                    }
                fi
            done
            if $_had_noglob; then
                shopt -s noglob
            else
                shopt -u noglob
            fi
        fi
    done

    if [[ -n "$copy_files" ]]; then
        echo "   Home skeleton created with files: ${copy_files}"
    else
        echo "   Home skeleton created (empty user directories)"
    fi
}

# ── Root device detection ───────────────────────────────────────────

# get_current_subvol: returns subvolume name without leading slash
get_current_subvol() {
    local raw
    raw=$(get_current_subvol_raw)
    echo "${raw#/}"
}

# get_current_subvol_raw: returns subvolume as reported by findmnt
# Uses sed instead of grep -P for portability
get_current_subvol_raw() {
    findmnt -n -o OPTIONS / | sed -n 's/.*subvol=\([^,]*\).*/\1/p' | head -1
}

# ── Root block device ────────────────────────────────────────────

_ROOT_DEVICE=""

get_root_device() {
    # Cache: python3 startup ~30ms, may be called multiple times
    if [[ -n "$_ROOT_DEVICE" ]]; then
        echo "$_ROOT_DEVICE"
        return 0
    fi

    local dev
    dev=$(python3 "${_ATOMIC_LIB_DIR}/rootdev.py" device 2>/dev/null)
    if [[ -n "$dev" && -e "$dev" ]]; then
        _ROOT_DEVICE="$dev"
        echo "$dev"
        return 0
    fi

    # Fallback to configured mapper name
    if [[ -e "/dev/mapper/${MAPPER_NAME}" ]]; then
        _ROOT_DEVICE="/dev/mapper/${MAPPER_NAME}"
        echo "$_ROOT_DEVICE"
        return 0
    fi

    echo "ERROR: Cannot detect root block device" >&2
    return 1
}

# ── Btrfs mount helpers ────────────────────────────────────────────

ensure_btrfs_mounted() {
    mkdir -p "$BTRFS_MOUNT" || return 1
    if ! mountpoint -q "$BTRFS_MOUNT" 2>/dev/null; then
        local root_dev
        root_dev=$(get_root_device) || return 1
        mount -o subvolid=5,nosuid,noexec,nodev "$root_dev" "$BTRFS_MOUNT" || {
            echo "ERROR: Failed to mount Btrfs root" >&2
            return 1
        }
    fi
}

validate_subvolume() {
    local subvol="$1"
    local mount="${2:-$BTRFS_MOUNT}"

    [[ -z "$subvol" ]] && return 1

    if ! mountpoint -q "$mount" 2>/dev/null; then
        ensure_btrfs_mounted || return 1
    fi

    [[ -d "${mount}/${subvol}" ]] || return 1
    btrfs subvolume show "${mount}/${subvol}" &>/dev/null
}

# ── Space checks ───────────────────────────────────────────────────

check_btrfs_space() {
    local mount_point="$1"
    local min_percent="${2:-10}"

    # Try btrfs-native output first, fall back to df
    local free_bytes total_bytes

    free_bytes=$(btrfs filesystem usage -b "$mount_point" 2>/dev/null |
        awk '/Free \(estimated\)/ {gsub(/[^0-9]/,"",$3); print $3}')
    total_bytes=$(btrfs filesystem usage -b "$mount_point" 2>/dev/null |
        awk '/Device size/ {gsub(/[^0-9]/,"",$3); print $3}')

    # Fallback to df if btrfs output parsing failed
    if [[ -z "$free_bytes" || -z "$total_bytes" || \
          ! "$free_bytes" =~ ^[0-9]+$ || ! "$total_bytes" =~ ^[0-9]+$ || \
          "$total_bytes" -eq 0 ]]; then
        local df_line
        df_line=$(df -B1 --output=size,avail "$mount_point" 2>/dev/null | tail -1)
        if [[ -n "$df_line" ]]; then
            read -r total_bytes free_bytes <<< "$df_line"
        fi
    fi

    if [[ -z "$free_bytes" || -z "$total_bytes" || \
          ! "$free_bytes" =~ ^[0-9]+$ || ! "$total_bytes" =~ ^[0-9]+$ || \
          "$total_bytes" -eq 0 ]]; then
        echo "WARN: Cannot determine disk space, continuing anyway" >&2
        return 0
    fi

    local free_percent=$((free_bytes * 100 / total_bytes))
    local free_gb=$((free_bytes / 1073741824))
    local min_abs_gb=2  # absolute minimum regardless of percentage

    if [[ $free_percent -lt $min_percent && $free_gb -lt $min_abs_gb ]]; then
        echo "ERROR: Low disk space: ${free_percent}% free (~${free_gb}GB), need ${min_percent}% or ${min_abs_gb}GB" >&2
        return 1
    fi

    if [[ $free_percent -lt $min_percent ]]; then
        echo "   Disk space: ${free_percent}% free (~${free_gb}GB) — below ${min_percent}% but above ${min_abs_gb}GB minimum"
    else
        echo "   Disk space: ${free_percent}% free (~${free_gb}GB)"
    fi
    return 0
}

check_esp_space() {
    local min_mb="${1:-100}"
    local avail_kb
    avail_kb=$(df -k --output=avail "$ESP" 2>/dev/null | tail -1 | tr -d ' ')

    if [[ -z "$avail_kb" ]]; then
        echo "WARN: Cannot check ESP space" >&2
        return 0
    fi

    local avail_mb=$((avail_kb / 1024))
    if [[ $avail_mb -lt $min_mb ]]; then
        echo "ERROR: Low ESP space: ${avail_mb}MB free (need ${min_mb}MB)" >&2
        return 1
    fi
    echo "   ESP space: ${avail_mb}MB free"
}

# ── Generation listing ──────────────────────────────────────────────

list_generations() {
    local -a gens=()
    local f
    # Use nullglob so the glob yields nothing instead of a literal pattern
    local _had_nullglob=false
    shopt -q nullglob && _had_nullglob=true
    shopt -s nullglob
    for f in "${ESP}/EFI/Linux/"*arch-*.efi; do
        [[ -f "$f" ]] || continue
        local name="${f##*/}"
        name="${name#0-active-}"
        name="${name#arch-}"
        name="${name%.efi}"
        [[ "$name" == *.protected ]] && continue
        gens+=("$name")
    done
    if $_had_nullglob; then
        shopt -s nullglob
    else
        shopt -u nullglob
    fi
    [[ ${#gens[@]} -eq 0 ]] && return 0
    printf '%s\n' "${gens[@]}" | sort -r
}

# ── UKI build cleanup helper (module-level, called by build_uki) ──

_build_uki_cleanup() {
    local os_release_tmp="$1"
    [[ -n "$os_release_tmp" ]] && rm -f "$os_release_tmp"
}

# ── UKI build (uses rootdev.py for cmdline auto-detection) ──────────

build_uki() {
    local gen_id="$1" new_root="$2" new_subvol="$3"
    local uki_path="${ESP}/EFI/Linux/arch-${gen_id}.efi"
    local os_release_tmp=""

    local kernel="${new_root}/boot/vmlinuz-${KERNEL_PKG}"
    local initramfs="${new_root}/boot/initramfs-${KERNEL_PKG}.img"

    [[ -f "$kernel" ]] || { echo "ERROR: No kernel: $kernel" >&2; return 1; }
    [[ -f "$initramfs" ]] || { echo "ERROR: No initramfs: $initramfs" >&2; return 1; }

    # Extract kernel version from modules directory inside the snapshot
    local uname_ver=""
    local modules_dir="${new_root}/usr/lib/modules"
    for d in "${modules_dir}"/*/; do
        [[ -f "${d}pkgbase" ]] || continue
        if [[ "$(cat "${d}pkgbase")" == "$KERNEL_PKG" ]]; then
            d="${d%/}"
            uname_ver="${d##*/}"
            break
        fi
    done

    # Fallback if pkgbase not found
    if [[ -z "$uname_ver" && -d "$modules_dir" ]]; then
        uname_ver=$(ls -1 "$modules_dir" | grep -E '^[0-9]+\.' | sort -V | tail -1)
    fi

    local root_cmdline
    root_cmdline=$(python3 "${_ATOMIC_LIB_DIR}/rootdev.py" cmdline "$new_subvol") || {
        echo "ERROR: Cannot detect root device for cmdline" >&2
        return 1
    }

    local cmdline="${root_cmdline} ${KERNEL_PARAMS}"

    os_release_tmp=$(mktemp) || { echo "ERROR: Cannot create temp file" >&2; return 1; }

    [[ -f "${new_root}/etc/os-release" ]] || {
        echo "ERROR: No os-release in snapshot" >&2
        _build_uki_cleanup "$os_release_tmp"; return 1
    }

    sed "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Arch Linux (${gen_id})\"|" \
        "${new_root}/etc/os-release" > "$os_release_tmp" || {
        echo "ERROR: Failed to create temp os-release" >&2
        _build_uki_cleanup "$os_release_tmp"; return 1
    }

    local -a ukify_args=(
        ukify build
        --linux="$kernel"
        --initrd="$initramfs"
        --cmdline="$cmdline"
        --os-release="@${os_release_tmp}"
        --output="$uki_path"
    )

    # Pass explicit kernel version to suppress autodetection warning
    if [[ -n "$uname_ver" ]]; then
        ukify_args+=(--uname="$uname_ver")
    fi

    if ! "${ukify_args[@]}" >&2; then
        echo "ERROR: ukify build failed" >&2
        _build_uki_cleanup "$os_release_tmp"; return 1
    fi

    [[ -f "$uki_path" ]] || {
        echo "ERROR: UKI not created" >&2
        _build_uki_cleanup "$os_release_tmp"; return 1
    }

    _build_uki_cleanup "$os_release_tmp"
    echo "$uki_path"
}

# ── Garbage collection ──────────────────────────────────────────────

garbage_collect() {
    local keep="${1:-$KEEP_GENERATIONS}"
    local dry_run="${2:-0}"
    local current_subvol
    current_subvol=$(get_current_subvol)

    [[ -z "$current_subvol" ]] && { echo "ERROR: Cannot determine current subvolume" >&2; return 1; }

    echo ":: Garbage collecting (keeping last ${keep} + current)..."

    ensure_btrfs_mounted || return 1

    local generations
    generations=$(list_generations)

    [[ -z "$generations" ]] && { echo "   No generations found"; return 0; }

    local -a to_keep=()
    local -a to_delete=()
    local count=0

    for gen_id in $generations; do
        local subvol_name="root-${gen_id}"

        if [[ "$subvol_name" == "$current_subvol" ]]; then
            to_keep+=("$gen_id (current)")
            continue
        fi

        if [[ -f "${ESP}/EFI/Linux/arch-${gen_id}.efi.protected" ]]; then
            to_keep+=("$gen_id (protected)")
            continue
        fi

        count=$((count + 1))
        if [[ $count -le $keep ]]; then
            to_keep+=("$gen_id")
        else
            to_delete+=("$gen_id")
        fi
    done

    if [[ ${#to_keep[@]} -gt 0 ]]; then
        printf '   Keeping: %s\n' "${to_keep[@]}"
    else
        echo "   Keeping: (none)"
    fi

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        echo "   Nothing to delete"
    else
        for gen_id in "${to_delete[@]}"; do
            delete_generation "$gen_id" "$dry_run" "$current_subvol"
        done
        if [[ "$dry_run" -eq 0 ]]; then
            echo "   Deleted ${#to_delete[@]} generation(s)"
        fi
    fi

    if ! mountpoint -q "$ESP" 2>/dev/null; then
        echo "   WARN: ESP not mounted, skipping orphan sweep" >&2
    else
        for d in "${BTRFS_MOUNT}"/root-*; do
            [[ -d "$d" ]] || continue
            local name="${d##*/}"
            local gen="${name#root-}"
            [[ "$name" == "$current_subvol" ]] && continue
            [[ "$gen" =~ ^[0-9]{8}-[0-9]{6} ]] || continue
            local uki_exists=0
            if [[ -f "${ESP}/EFI/Linux/arch-${gen}.efi" ]] || \
               [[ -f "${ESP}/EFI/Linux/0-active-arch-${gen}.efi" ]]; then
                uki_exists=1
            fi
            if [[ $uki_exists -eq 0 ]]; then
                if [[ -f "${ESP}/EFI/Linux/arch-${gen}.efi.protected" ]]; then
                    echo "   REFUSE: ${gen} is protected (remove protection first)"
                    continue
                fi
                echo "   Orphan: ${name} (no UKI)"
                if [[ "$dry_run" -eq 0 ]]; then
                    btrfs subvolume delete "$d" 2>/dev/null ||
                        echo "   WARN: Failed to delete orphan ${name}" >&2
                fi
            fi
        done

        for uki in "${ESP}/EFI/Linux/"{arch-,0-active-arch-}*.efi; do
            [[ -e "$uki" ]] || continue
            local uki_name="${uki##*/}"
            uki_name="${uki_name#0-active-}"
            uki_name="${uki_name#arch-}"; uki_name="${uki_name%.efi}"
            [[ "root-${uki_name}" == "$current_subvol" ]] && continue
            [[ "$uki_name" =~ ^[0-9]{8}-[0-9]{6} ]] || continue
            if [[ ! -d "${BTRFS_MOUNT}/root-${uki_name}" ]]; then
                echo "   Orphan UKI: ${uki_name} (no subvolume)"
                [[ "$dry_run" -eq 0 ]] && rm -f "$uki"
            fi
        done

        # Orphan home subvolumes — warn only, never auto-delete (user data)
        for d in "${BTRFS_MOUNT}"/home-*; do
            [[ -d "$d" ]] || continue
            local home_name="${d##*/}"
            local tag="${home_name#home-}"
            local has_gen=0
            # Extract tag from each UKI via regex, not glob suffix match.
            # Glob "*-${tag}.efi" would false-positive on tags sharing
            # a suffix (e.g. "super-kde" matching home-kde).
            for uki in "${ESP}/EFI/Linux/arch-"*.efi; do
                [[ -e "$uki" ]] || continue
                local uki_gen="${uki##*/}"
                uki_gen="${uki_gen#arch-}"; uki_gen="${uki_gen%.efi}"
                local uki_tag=""
                [[ "$uki_gen" =~ ^[0-9]{8}-[0-9]{6}-(.+)$ ]] && uki_tag="${BASH_REMATCH[1]}"
                [[ "$uki_tag" == "$tag" ]] && { has_gen=1; break; }
            done
            if [[ $has_gen -eq 0 ]]; then
                echo "   Orphan home: ${home_name} (no generations with tag '${tag}')"
                echo "   To remove: btrfs subvolume delete ${BTRFS_MOUNT}/${home_name}"
            fi
        done
    fi

    echo ":: Garbage collection done"
}

# ── Orphan home warning ──────────────────────────────────────────────
# Warns if deleting the given generation(s) would leave home-<tag>
# subvolumes with no remaining generations referencing their tag.
# Args: gen_id [gen_id ...]

warn_orphan_homes() {
    local -a del_ids=("$@")
    local -A seen_tags=()
    local gen_id tag uki_file uki_gen del_id

    for gen_id in "${del_ids[@]}"; do
        [[ "$gen_id" =~ ^[0-9]{8}-[0-9]{6}-(.+)$ ]] || continue
        tag="${BASH_REMATCH[1]}"
        [[ -z "${seen_tags[$tag]+x}" ]] || continue
        seen_tags[$tag]=1
        [[ -d "${BTRFS_MOUNT}/home-${tag}" ]] || continue

        # Any generation NOT in the delete list that also uses this tag?
        local has_other=0
        for uki_file in "${ESP}/EFI/Linux/arch-"*.efi; do
            [[ -e "$uki_file" ]] || continue
            uki_gen="${uki_file##*/}"
            uki_gen="${uki_gen#arch-}"; uki_gen="${uki_gen%.efi}"
            # Extract tag from this UKI's gen_id
            local uki_tag=""
            [[ "$uki_gen" =~ ^[0-9]{8}-[0-9]{6}-(.+)$ ]] && uki_tag="${BASH_REMATCH[1]}"
            [[ "$uki_tag" == "$tag" ]] || continue
            # Same tag — is this UKI being deleted?
            local in_list=0
            for del_id in "${del_ids[@]}"; do
                [[ "$uki_gen" == "$del_id" ]] && { in_list=1; break; }
            done
            [[ $in_list -eq 0 ]] && { has_other=1; break; }
        done

        [[ $has_other -eq 0 ]] || continue
        echo "NOTE: home-${tag} will become orphaned (not auto-deleted)"
        echo "      To remove: btrfs subvolume delete ${BTRFS_MOUNT}/home-${tag}"
    done
}

delete_generation() {
    local gen_id="$1"
    local dry_run="${2:-0}"
    local current_subvol="${3:-}"

    # Validate gen_id format before any destructive operations
    if [[ ! "$gen_id" =~ ^[0-9]{8}-[0-9]{6}(-.+)?$ ]]; then
        echo "ERROR: Invalid generation ID format: ${gen_id}" >&2
        return 1
    fi

    if [[ -z "$current_subvol" ]]; then
        current_subvol=$(get_current_subvol)
        [[ -z "$current_subvol" ]] && {
            echo "ERROR: Cannot determine current subvolume, refusing to delete" >&2
            return 1
        }
    fi

    if [[ "root-${gen_id}" == "$current_subvol" ]]; then
        echo "   REFUSE: ${gen_id} is current" >&2
        return 1
    fi

    if [[ -f "${ESP}/EFI/Linux/arch-${gen_id}.efi.protected" ]]; then
        echo "   REFUSE: ${gen_id} is protected (remove protection first)" >&2
        return 1
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        echo "   Would delete: ${gen_id}"
        return 0
    fi

    echo "   Deleting: ${gen_id}"
    rm -f "${ESP}/EFI/Linux/arch-${gen_id}.efi"
    rm -f "${ESP}/EFI/Linux/0-active-arch-${gen_id}.efi"
    rm -f "${ESP}/EFI/Linux/arch-${gen_id}.efi.protected"
    if [[ -d "${BTRFS_MOUNT}/root-${gen_id}" ]]; then
        btrfs subvolume delete "${BTRFS_MOUNT}/root-${gen_id}" 2>/dev/null || {
            echo "   WARN: Failed to delete subvolume root-${gen_id}" >&2
        }
    fi
}
