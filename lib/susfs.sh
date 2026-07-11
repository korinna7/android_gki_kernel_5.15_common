#!/bin/bash
# ==============================================================================
# SUSFS Integration Module for KernelSU
# Adds SUSFS (SuS File System) root-hiding patches to GKI kernels
# ==============================================================================

# Source common functions
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$MODULE_DIR/common.sh"

# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Primary SUSFS repo (original author)
SUSFS_PRIMARY_URL="https://gitlab.com/simonpunk/susfs4ksu.git"
# Fallback mirror (GitHub, maintained by community)
SUSFS_FALLBACK_URL="https://github.com/ShirkNeko/susfs4ksu.git"
# SUSFS branch for android13-5.15: gki-android13-5.15
SUSFS_BRANCH="gki-android13-5.15"
# Optional SUSFS commit pin (env var). Empty = use branch tip from clone.
SUSFS_PINNED_COMMIT="${SUSFS_PINNED_COMMIT:-}"
# Clone destination (sibling to source, not inside source)
SUSFS_CLONE_DIR=""

# ==============================================================================
# INTERNAL HELPERS
# ==============================================================================

# Extract kernel sublevel from Makefile
get_kernel_sublevel() {
    local sublevel
    sublevel=$(grep '^SUBLEVEL = ' "$KERNEL_SRC/Makefile" | awk '{print $3}')
    if [[ ! "$sublevel" =~ ^[0-9]+$ ]]; then
        sublevel=99999
    fi
    echo "$sublevel"
}

# Clone SUSFS repo with fallback
clone_susfs_repo() {
    local clone_dir="$1"

    log "Cloning SUSFS repository (branch: $SUSFS_BRANCH)..."
    if git clone "$SUSFS_PRIMARY_URL" -b "$SUSFS_BRANCH" --depth 1 "$clone_dir" 2>/dev/null; then
        log "✓ Cloned from $SUSFS_PRIMARY_URL"
    elif git clone "$SUSFS_FALLBACK_URL" -b "$SUSFS_BRANCH" --depth 1 "$clone_dir" 2>/dev/null; then
        log "✓ Cloned from GitHub mirror: $SUSFS_FALLBACK_URL"
    else
        error "Failed to clone SUSFS from both primary and fallback URLs"
        error "  Primary: $SUSFS_PRIMARY_URL (branch: $SUSFS_BRANCH)"
        error "  Fallback: $SUSFS_FALLBACK_URL (branch: $SUSFS_BRANCH)"
        exit 1
    fi

    # Pin to fixed commit if specified
    if [ -n "$SUSFS_PINNED_COMMIT" ]; then
        log "Checking out SUSFS: $SUSFS_PINNED_COMMIT"
        git -C "$clone_dir" fetch --depth=50 origin "$SUSFS_PINNED_COMMIT" 2>/dev/null || true
        git -C "$clone_dir" checkout "$SUSFS_PINNED_COMMIT" || {
            error "Failed to checkout SUSFS commit: $SUSFS_PINNED_COMMIT"
            exit 1
        }
    fi

    # Log the actual commit used for traceability
    local used_commit used_date
    used_commit=$(git -C "$clone_dir" rev-parse --short HEAD)
    used_date=$(git -C "$clone_dir" log -1 --date=format:'%Y-%m-%d %H:%M:%S %z' --format='%cd')
    log "SUSFS commit: $used_commit ($used_date)"
    echo "SUSFS_COMMIT=$used_commit" >> "$GITHUB_ENV" 2>/dev/null || true
}

# Copy SUSFS source files into the kernel tree
copy_susfs_files() {
    local susfs_dir="$1"

    log "Copying SUSFS filesystem sources into kernel tree..."

    # Copy fs/ files (susfs.c, sus_su.c, susfs.h, sus_su.h)
    if [ -d "$susfs_dir/kernel_patches/fs" ]; then
        cp "$susfs_dir/kernel_patches/fs/"* "$KERNEL_SRC/fs/"
        log "  ✓ Copied fs/ files: $(ls "$susfs_dir/kernel_patches/fs/" | tr '\n' ' ')"
    else
        warn "  SUSFS fs/ directory not found at $susfs_dir/kernel_patches/fs"
    fi

    # Copy include/linux/ headers (susfs_def.h, susfs.h)
    if [ -d "$susfs_dir/kernel_patches/include/linux" ]; then
        cp "$susfs_dir/kernel_patches/include/linux/"* "$KERNEL_SRC/include/linux/"
        log "  ✓ Copied include/linux/ headers: $(ls "$susfs_dir/kernel_patches/include/linux/" | tr '\n' ' ')"
    else
        warn "  SUSFS include/linux/ directory not found"
    fi

    log "✓ SUSFS source files copied"
}

# Patch KernelSU itself to enable SUSFS support (for Official KSU)
patch_kernelsu_for_susfs() {
    local susfs_dir="$1"
    local patch_file="$susfs_dir/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

    if [ ! -f "$patch_file" ]; then
        warn "SUSFS KernelSU enablement patch not found: $patch_file"
        warn "This may be OK for non-Official KSU variants (Next/SukiSU/ReSukiSU have built-in SUSFS)"
        return 0
    fi

    log "Applying KernelSU-side SUSFS enablement patch..."

    cd "$KERNEL_SRC/KernelSU"

    if [ ! -d "kernel" ]; then
        error "KernelSU/kernel directory not found. Is KernelSU properly set up?"
        cd "$KERNEL_SRC"
        return 1
    fi

    cp "$patch_file" ./

    # Compatibility fix: convert kernel/Makefile → kernel/Kbuild in the patch
    # Newer KSU moved from Makefile to Kbuild; older SUSFS patches may not reflect this
    if grep -q '^diff --git a/kernel/Makefile b/kernel/Makefile' 10_enable_susfs_for_ksu.patch \
        && ! grep -q '^diff --git a/kernel/Kbuild b/kernel/Kbuild' 10_enable_susfs_for_ksu.patch; then
        log "  Fixing patch: kernel/Makefile → kernel/Kbuild"
        sed -i 's|kernel/Makefile|kernel/Kbuild|g' 10_enable_susfs_for_ksu.patch
    fi

    # Apply the patch (--forward: skip if already applied)
    if patch -p1 --forward --no-backup-if-mismatch < 10_enable_susfs_for_ksu.patch; then
        log "✓ KernelSU SUSFS enablement patch applied successfully"
    else
        warn "KernelSU SUSFS enablement patch may have partially failed"
        warn "This can happen if SUSFS support is already built-in (SukiSU/Next variants)"
        warn "Check manually if you encounter build errors related to KSU_SUSFS"
    fi

    rm -f 10_enable_susfs_for_ksu.patch
    cd "$KERNEL_SRC"
}

# ==============================================================================
# CONFLICT RESOLUTION — Pre-Patch Context Adjustments
# ==============================================================================

# For 5.15.194 (SUBLEVEL=194), most old-kernel workarounds are NOT needed.
# But we keep the functions for completeness and defensive checking.

apply_susfs_pre_patch_fixes() {
    local sublevel="$1"
    cd "$KERNEL_SRC"

    log "Checking for pre-patch context adjustments (sub_level=$sublevel)..."

    # android13-5.15, sub_level ≤ 41: namespace.c and open.c need mnt_idmapping.h
    # At sub_level 194, this is NOT needed. But check defensively.
    if [ "$sublevel" -le 41 ] 2>/dev/null; then
        log "  Sub_level ≤ 41 — applying mnt_idmapping.h injections..."

        if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
            sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
            log "    ✓ Injected mnt_idmapping.h into namespace.c"
        fi

        if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
            sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
            log "    ✓ Injected mnt_idmapping.h into open.c"
        fi

        # fdinfo.c context adjustment for old inotify code
        if grep -qF 'u32 mask = mark->mask & IN_ALL_EVENTS;' fs/notify/fdinfo.c; then
            log "  Adjusting fdinfo.c for old inotify context..."
            sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
            perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
            perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
        fi
    else
        log "  Sub_level $sublevel > 41 — skipping mnt_idmapping.h / fdinfo.c fixes"
    fi

    log "✓ Pre-patch checks complete"
}

# ==============================================================================
# CONFLICT RESOLUTION — Post-Patch Fixes
# ==============================================================================

# Fix: namespace.c missing SUSFS declarations
# The SUSFS patch adds code references to namespace.c but the #include
# and extern declaration hunks may fail if the context doesn't match.
fix_namespace_susfs_mount_decls() {
    local label="$1"
    local marker_pattern="$2"

    if ! grep -q "$marker_pattern" fs/namespace.c; then
        return 0  # No SUSFS markers → nothing to fix
    fi

    log "  [$label] namespace.c has SUSFS markers — checking declarations..."

    # Inject susfs_def.h include if missing
    if ! grep -qF '#include <linux/susfs_def.h>' fs/namespace.c; then
        if grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
            sed -i '/#include <linux\/mnt_idmapping.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux\/susfs_def.h>\n#endif' fs/namespace.c
        elif grep -qF '#include <linux/shmem_fs.h>' fs/namespace.c; then
            sed -i '/#include <linux\/shmem_fs.h>/a #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux\/susfs_def.h>\n#endif' fs/namespace.c
        else
            sed -i '0,/^#include /s//#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux\/susfs_def.h>\n#endif\n&/' fs/namespace.c
        fi
        log "    ✓ Injected susfs_def.h into namespace.c"
    fi

    # Inject extern declarations if missing
    if ! grep -q 'extern bool susfs_is_current_ksu_domain' fs/namespace.c; then
        if grep -q '#include "internal.h"' fs/namespace.c; then
            sed -i '/#include "internal.h"/a \\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n\n#define CL_COPY_MNT_NS BIT(25)\n\n#endif' fs/namespace.c
            log "    ✓ Injected SUSFS extern declarations into namespace.c"
        else
            warn "    Could not find '#include \"internal.h\"' — skipping extern injection"
        fi
    fi
}

# Fix: task_mmu.c missing susfs_def.h
# The SUSFS patch adds SUSFS_IS_INODE_SUS_MAP / SUSFS_IS_INODE_OPEN_REDIRECT
# macros in task_mmu.c but the header hunk may not apply cleanly.
fix_task_mmu_susfs_header() {
    if ! grep -q 'SUSFS_IS_INODE_SUS_MAP\|SUSFS_IS_INODE_OPEN_REDIRECT' fs/proc/task_mmu.c; then
        return 0  # No SUSFS macros → nothing to fix
    fi

    if grep -qF '#include <linux/susfs_def.h>' fs/proc/task_mmu.c; then
        return 0  # Already has the include
    fi

    log "  task_mmu.c has SUSFS macros but lacks susfs_def.h — injecting..."

    if grep -qF '#include <linux/pkeys.h>' fs/proc/task_mmu.c; then
        sed -i '/#include <linux\/pkeys.h>/a #if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux\/susfs_def.h>\n#endif' fs/proc/task_mmu.c
    elif grep -qF '#include <linux/uaccess.h>' fs/proc/task_mmu.c; then
        sed -i '/#include <linux\/uaccess.h>/a #if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux\/susfs_def.h>\n#endif' fs/proc/task_mmu.c
    else
        sed -i '0,/^#include /s//#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux\/susfs_def.h>\n#endif\n&/' fs/proc/task_mmu.c
    fi
    log "    ✓ Injected susfs_def.h into task_mmu.c"
}

# Fix: mmap.c vm_flags_clear() compatibility
# Some GKI branches (2024-11) added vm_flags_clear() calls but 5.15's mm.h
# may not provide the helper function.
fix_mmap_vm_flags_clear() {
    if grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' mm/mmap.c; then
        log "  Fixing mmap.c vm_flags_clear() → direct flag manipulation..."
        sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' mm/mmap.c
        log "    ✓ Replaced vm_flags_clear() in mmap.c"
    fi
}

# Fix: task_mmu.c show_pad workaround
# Old kernel versions have a "goto show_pad" that interferes with SUSFS.
fix_task_mmu_show_pad() {
    local max_sub="$1"
    local sublevel="$2"

    if [ "$sublevel" -le "$max_sub" ] 2>/dev/null; then
        if grep -qF 'goto show_pad;' fs/proc/task_mmu.c; then
            log "  Fixing task_mmu.c show_pad → return 0 (sub_level ≤ $max_sub)..."
            sed -i 's/goto show_pad;/return 0;/' fs/proc/task_mmu.c
            log "    ✓ Replaced goto show_pad"
        fi
    fi
}

apply_susfs_post_patch_fixes() {
    local sublevel="$1"
    cd "$KERNEL_SRC"

    log "Applying post-patch conflict resolution checks..."

    # 1. namespace.c SUSFS mount declarations (always check)
    fix_namespace_susfs_mount_decls \
        "android13-5.15" \
        'DEFAULT_KSU_MNT_ID\|VFSMOUNT_MNT_FLAGS_KSU_UNSHARED_MNT\|CL_COPY_MNT_NS'

    # 2. task_mmu.c missing susfs_def.h (always check)
    fix_task_mmu_susfs_header

    # 3. mmap.c vm_flags_clear() fix (always check — no-op if pattern absent)
    fix_mmap_vm_flags_clear

    # 4. task_mmu.c show_pad fix (only for sub_level ≤ 148)
    fix_task_mmu_show_pad 148 "$sublevel"

    # 5. susfs.c i_uid_into_mnt fix for sub_level ≤ 41
    if [ "$sublevel" -le 41 ] 2>/dev/null; then
        if [ -f fs/susfs.c ]; then
            log "  Fixing susfs.c i_uid_into_mnt for old sublevel..."
            sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
            sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
            log "    ✓ Applied susfs.c uid fix"
        fi
    fi

    log "✓ Post-patch fixes complete"
}

# ==============================================================================
# UNICODE BYPASS FIX
# ==============================================================================

# SUSFS on 5.10/5.15 needs a fix for Unicode normalization bypass in fs/unicode/
# The patch is sourced from the Numbersf/Action-Build community repo.
apply_unicode_bypass_fix() {
    log "Applying Unicode normalization bypass fix for 5.15..."

    local fix_url="https://raw.githubusercontent.com/Numbersf/Action-Build/main/patches/unicode_bypass_fix_6.1-.patch"
    local fix_file="$KERNEL_SRC/unicode_bypass_fix.patch"

    cd "$KERNEL_SRC"

    if ! curl -LSs --connect-timeout 30 --max-time 60 "$fix_url" -o "$fix_file"; then
        warn "Failed to download Unicode bypass fix from $fix_url"
        warn "This is non-critical — build may still succeed"
        return 0
    fi

    if [ -s "$fix_file" ]; then
        if patch -p1 --forward --no-backup-if-mismatch < "$fix_file" 2>/dev/null; then
            log "✓ Unicode bypass fix applied"
        else
            warn "Unicode bypass fix failed to apply (may already be patched)"
        fi
    fi

    rm -f "$fix_file"
}

# ==============================================================================
# DEFCONFIG
# ==============================================================================

add_susfs_defconfig() {
    local defconfig="$KERNEL_SRC/arch/arm64/configs/gki_defconfig"

    log "Adding SUSFS kernel config entries to gki_defconfig..."

    # KernelSU base (ensure it's present)
    if ! grep -q "^CONFIG_KSU=y" "$defconfig"; then
        echo "CONFIG_KSU=y" >> "$defconfig"
        log "  + CONFIG_KSU=y"
    fi

    # SUSFS core and sub-options
    local susfs_configs=(
        "CONFIG_KSU_SUSFS=y"
        "CONFIG_KSU_SUSFS_SUS_PATH=y"
        "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
        "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
        "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
        "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
        "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
        "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
        "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
        "CONFIG_KSU_SUSFS_SUS_MAP=y"
    )

    for cfg in "${susfs_configs[@]}"; do
        if ! grep -q "^${cfg%%=*}" "$defconfig"; then
            echo "$cfg" >> "$defconfig"
            log "  + $cfg"
        fi
    done

    log "✓ SUSFS defconfig entries added"
}

# ==============================================================================
# MAIN ENTRY POINT
# ==============================================================================

setup_susfs() {
    log "============================================"
    log "Setting up SUSFS for KernelSU..."
    log "============================================"

    # Precondition: KernelSU must be set up first
    if [ ! -d "$KERNEL_SRC/KernelSU" ]; then
        error "KernelSU directory not found at $KERNEL_SRC/KernelSU"
        error "SUSFS requires KernelSU to be set up first (use --ksu or ensure setup_kernelsu ran)."
        exit 1
    fi

    if [ ! -d "$KERNEL_SRC/KernelSU/kernel" ]; then
        error "KernelSU/kernel directory not found. KernelSU setup may be incomplete."
        exit 1
    fi

    # Get kernel sublevel for version-dependent fixes
    local sublevel
    sublevel=$(get_kernel_sublevel)
    log "Detected kernel sublevel: $sublevel"

    # Compute clone path (sibling to kernel source, not inside it)
    SUSFS_CLONE_DIR="$KERNEL_SRC/../susfs4ksu"
    rm -rf "$SUSFS_CLONE_DIR"

    # Step 1: Clone SUSFS repo
    clone_susfs_repo "$SUSFS_CLONE_DIR"

    # Step 2: Copy SUSFS source files into kernel tree
    copy_susfs_files "$SUSFS_CLONE_DIR"

    # Step 3: Copy and apply the main kernel patch
    local main_patch="$SUSFS_CLONE_DIR/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
    if [ -f "$main_patch" ]; then
        cp "$main_patch" "$KERNEL_SRC/"
        log "Copied main SUSFS patch: 50_add_susfs_in_gki-android13-5.15.patch"
    else
        warn "Main SUSFS patch not found at expected path: $main_patch"
        warn "Available patches:"
        ls "$SUSFS_CLONE_DIR/kernel_patches/"*.patch 2>/dev/null || warn "  (none found)"
    fi

    # Step 4: Patch KernelSU itself to enable SUSFS hooks
    patch_kernelsu_for_susfs "$SUSFS_CLONE_DIR"

    # Step 5: Pre-patch context adjustments (version-dependent)
    apply_susfs_pre_patch_fixes "$sublevel"

    # Step 6: Apply main SUSFS kernel patch
    cd "$KERNEL_SRC"
    if [ -f "50_add_susfs_in_gki-android13-5.15.patch" ]; then
        log "Applying main SUSFS kernel patch..."
        if patch -p1 --forward --no-backup-if-mismatch < 50_add_susfs_in_gki-android13-5.15.patch; then
            log "✓ Main SUSFS patch applied successfully"
        else
            warn "Main SUSFS patch may have partially failed to apply"
            warn "This can happen if some hunks are already applied or context differs"
            warn "Post-patch fixes will attempt to resolve remaining issues..."
        fi
        rm -f 50_add_susfs_in_gki-android13-5.15.patch
    fi

    # Step 7: Revert pre-patch temporary adjustments (for sub_level ≤ 41)
    if [ "$sublevel" -le 41 ] 2>/dev/null; then
        log "Reverting pre-patch temporary adjustments..."

        # Revert namespace.c mnt_idmapping.h injection
        sed -i '/^#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c 2>/dev/null || true
        # Revert open.c mnt_idmapping.h injection
        sed -i '/^#include <linux\/mnt_idmapping.h>$/d' fs/open.c 2>/dev/null || true

        # Revert fdinfo.c adjustments
        if grep -qF 'inotify_mark_user_mask(mark)' fs/notify/fdinfo.c; then
            perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask \& IN_ALL_EVENTS;/m' fs/notify/fdinfo.c 2>/dev/null || true
            perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c 2>/dev/null || true
            perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c 2>/dev/null || true
        fi

        # Revert susfs.c uid fix
        if [ -f fs/susfs.c ]; then
            sed -i 's|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|i_uid_into_mnt(i_user_ns(\&fi->inode), \&fi->inode).val|g' fs/susfs.c 2>/dev/null || true
            sed -i 's|i_uid_into_mnt(\&init_user_ns, inode).val|i_uid_into_mnt(i_user_ns(inode), inode).val|g' fs/susfs.c 2>/dev/null || true
        fi

        log "✓ Pre-patch adjustments reverted"
    fi

    # Step 8: Post-patch conflict resolution
    apply_susfs_post_patch_fixes "$sublevel"

    # Step 9: Unicode bypass fix (needed for 5.15)
    apply_unicode_bypass_fix

    # Step 10: Add SUSFS config entries to defconfig
    add_susfs_defconfig

    # Step 11: Remove check_defconfig constraint (Bazel compatibility)
    local build_config_gki="$WORKSPACE_DIR/common/build.config.gki"
    if [ -f "$build_config_gki" ]; then
        log "Disabling check_defconfig for SUSFS compatibility..."
        sed -i 's/check_defconfig//' "$build_config_gki"
        log "✓ check_defconfig disabled in GKI build config"
    fi

    log "============================================"
    log "SUSFS setup complete!"
    log "============================================"
}
