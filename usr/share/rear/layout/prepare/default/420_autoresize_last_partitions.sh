#
# layout/prepare/default/420_autoresize_last_partitions.sh
#
# Try to automatically resize active last partitions on all active disks
# if the disk size had changed (i.e. only in migration mode).
#
# When AUTORESIZE_PARTITIONS is false, no partition is resized.
#
# When AUTORESIZE_PARTITIONS is true, all active partitions on all active disks
# get resized by the separated 430_autoresize_all_partitions.sh script. 
#
# A true or false value must be the first one in the AUTORESIZE_PARTITIONS array.
#
# When the first value in AUTORESIZE_PARTITIONS is neither true nor false
# only the last active partition on each active disk gets resized.
#
# All other values in the AUTORESIZE_PARTITIONS array specify partition device nodes
# e.g. as in AUTORESIZE_PARTITIONS=( /dev/sda2 /dev/sdb3 )
# where last partitions with those partition device nodes should be resized
# regardless of what is specified in the AUTORESIZE_EXCLUDE_PARTITIONS array.
#
# The values in the AUTORESIZE_EXCLUDE_PARTITIONS array specify partition device nodes
# where partitions with those partition device nodes are excluded from being resized.
# The special values 'boot', 'swap', and 'efi' specify that
#  - partitions where its filesystem mountpoint contains 'boot' or 'bios' or 'grub'
#    or where its GPT name or flags contain 'boot' or 'bios' or 'grub' (anywhere case insensitive)
#  - partitions for which an active 'swap' entry exists in disklayout.conf
#    or where its GPT name or flags contain 'swap' (anywhere case insensitive)
#  - partitions where its filesystem mountpoint contains 'efi' or 'esp'
#    or where its GPT name or flags contains 'efi' or 'esp' (anywhere case insensitive)
# are excluded from being resized e.g. as in
# AUTORESIZE_EXCLUDE_PARTITIONS=( boot swap efi /dev/sdb3 /dev/sdc4 )
#
# The last active partition on each active disk gets resized but nothing more.
# In particular this does not resize volumes on top of the affected partitions.
# To migrate volumes on disk where the disk size had changed the user must in advance
# manually adapt his disklayout.conf file before he runs "rear recover".
#
# In general ReaR is not meant to somehow "optimize" a system during "rear recover".
# ReaR is meant to recreate a system as much as possible exactly as it was before.
# Accordingly this automated resizing implements a "minimal changes" approach:
#
# When the new disk is a bit smaller (at most AUTOSHRINK_DISK_SIZE_LIMIT_PERCENTAGE percent),
# only the last (active) partition gets shrinked but all other partitions are not changed.
# When the new disk is smaller than AUTOSHRINK_DISK_SIZE_LIMIT_PERCENTAGE percent it errors out.
# To migrate onto a substantially smaller new disk the user must in advance
# manually adapt his disklayout.conf file before he runs "rear recover".
#
# When the new disk is only a bit bigger (less than AUTOINCREASE_DISK_SIZE_THRESHOLD_PERCENTAGE percent),
# no partition gets increased (which leaves the bigger disk space at the end of the disk unused).
# When the new disk is substantially bigger (at least AUTOINCREASE_DISK_SIZE_THRESHOLD_PERCENTAGE percent),
# only the last (active) partition gets increased but all other partitions are not changed.
# To migrate various partitions onto a substantially bigger new disk the user must in advance
# manually adapt his disklayout.conf file before he runs "rear recover".
#
# Because only the end value of the last partition may get changed, the partitioning alignment
# of the original system is not changed, cf. https://github.com/rear/rear/issues/102
#
# Because only the last active (i.e. not commented in disklayout.conf) partition on a disk
# may get changed, things go wrong if another partition is actually the last one on the disk
# but that other partition is commented in disklayout.conf (e.g. because that partition
# is a partition of another operating system that is not mounted during "rear mkrescue").
# To migrate a system with a non-active last partition onto a bigger or smaller new disk
# the user must in advance manually adapt his disklayout.conf file before he runs "rear recover".

# Skip if not in migration mode:
is_true "$MIGRATION_MODE" || return 0

# Skip if automatically resize partitions is explicity unwanted:
is_false "$AUTORESIZE_PARTITIONS" && return 0

# Skip resizing only the last partition if resizing all partitions is explicity wanted
# which is done by the separated 430_autoresize_all_partitions.sh script:
is_true "$AUTORESIZE_PARTITIONS" && return 0

# Write new disklayout with resized partitions to LAYOUT_FILE.resized_last_partition:
local disklayout_resized_last_partition="$LAYOUT_FILE.resized_last_partition"
cp "$LAYOUT_FILE" "$disklayout_resized_last_partition"
backup_file "$LAYOUT_FILE"

# Set fallbacks if mandatory values are not set (should be set in default.conf):
test "$AUTORESIZE_EXCLUDE_PARTITIONS" || AUTORESIZE_EXCLUDE_PARTITIONS=( boot swap efi )
test "$AUTOINCREASE_DISK_SIZE_THRESHOLD_PERCENTAGE" || AUTOINCREASE_DISK_SIZE_THRESHOLD_PERCENTAGE=10
test "$AUTOSHRINK_DISK_SIZE_LIMIT_PERCENTAGE" || AUTOSHRINK_DISK_SIZE_LIMIT_PERCENTAGE=2

local component_type junk
local disk_device old_disk_size
local sysfsname new_disk_size
local max_part_start last_part_dev last_part_start last_part_size last_part_type last_part_flags
local disk_dev part_size part_start part_type part_flags part_dev
local last_part_is_resizeable last_part_filesystem_entry last_part_filesystem_mountpoint egrep_pattern
local last_part_is_boot last_part_is_swap last_part_is_efi
local MiB new_disk_size_MiB first_byte_after_last_MiB_on_disk new_last_part_size
local disk_size_difference increase_threshold_difference max_shrink_difference

# Example 'disk' entry in disklayout.conf:
#   # Disk /dev/sda
#   # Format: disk <devname> <size(bytes)> <partition label type>
#   disk /dev/sda 21474836480 msdos
while read component_type disk_device old_disk_size junk ; do
    Log "Examining $disk_device to automatically resize its last active partition"

    sysfsname=$( get_sysfs_name $disk_device )
    test "$sysfsname" || Error "Failed to get_sysfs_name() for $disk_device"
    test -d "/sys/block/$sysfsname" || Error "No '/sys/block/$sysfsname' directory for $disk_device"

    new_disk_size=$( get_disk_size "$sysfsname" )
    is_positive_integer $new_disk_size || Error "Failed to get_disk_size() for $disk_device"
    # Skip if the size of the new disk (e.g. sda) is same as the size of the old disk (e.g. also sda):
    if test $new_disk_size -eq $old_disk_size ; then
        Log "Skipping $disk_device (size of new disk same as size of old disk)"
        continue
    fi

    # Find the last partition for the current disk in disklayout.conf:
    # Example partitions 'part' entries in disklayout.conf:
    #   # Partitions on /dev/sda
    #   # Format: part <device> <partition size(bytes)> <partition start(bytes)> <partition type|name> <flags> /dev/<partition>
    #   part /dev/sda 1569718272 1048576 primary none /dev/sda1
    #   part /dev/sda 19904069632 1570766848 primary boot /dev/sda2
    # The last partition is the /dev/<partition> with biggest <partition start(bytes)> value.
    max_part_start=0
    last_part_dev=""
    last_part_start=0
    last_part_size=0
    while read component_type disk_dev part_size part_start part_type part_flags part_dev junk ; do
        Log "Checking $part_dev if it is the last partition on $disk_device"
        if test $part_start -ge $max_part_start ; then
            max_part_start=$part_start
            last_part_dev="$part_dev"
            last_part_start="$part_start"
            last_part_size="$part_size"
            last_part_type="$part_type"
            last_part_flags="$part_flags"
        fi
    done < <( grep "^part $disk_device" "$LAYOUT_FILE" )
    test "$last_part_dev" || Error "Failed to determine /dev/<partition> for last partition on $disk_device"
    is_positive_integer $last_part_start || Error "Failed to determine partition start for $last_part_dev"
    Log "Found $last_part_dev as last partition on $disk_device"

    # Determine if the last partition is resizeable:
    Log "Determining if last partition $last_part_dev is resizeable"
    last_part_is_resizeable=""
    if IsInArray "$last_part_dev" ${AUTORESIZE_PARTITIONS[@]} ; then
        last_part_is_resizeable="yes"
        Log "Last partition should be resized ($last_part_dev in AUTORESIZE_PARTITIONS)"
    else
        # Example filesystem 'fs' entry in disklayout.conf (excerpt):
        #  # Format: fs <device> <mountpoint> <fstype> ...
        #  fs /dev/sda3 /boot/efi vfat ...
        last_part_filesystem_entry=( $( grep "^fs $last_part_dev " "$LAYOUT_FILE" ) )
        last_part_filesystem_mountpoint="${last_part_filesystem_entry[2]}"
        # Intentionally all tests to exclude a partition from being resized are run
        # to get all reasons shown (in the log) why one same partition is not resizeable.
        # Do not resize partitions that are explicitly specified to be excluded from being resized:
        if IsInArray "$last_part_dev" ${AUTORESIZE_EXCLUDE_PARTITIONS[@]} ; then
            last_part_is_resizeable="no"
            Log "Last partition $last_part_dev not resizeable (excluded from being resized in AUTORESIZE_EXCLUDE_PARTITIONS)"
        fi
        # Do not resize partitions that are used during boot:
        if IsInArray "boot" ${AUTORESIZE_EXCLUDE_PARTITIONS[@]} ; then
            last_part_is_boot=''
            # A partition is considered to be used during boot
            # when its GPT name or flags contain 'boot' or 'bios' or 'grub' (anywhere case insensitive):
            egrep_pattern='boot|bios|grub'
            grep -E -i "$egrep_pattern" <<< $( echo $last_part_type ) && last_part_is_boot="yes"
            grep -E -i "$egrep_pattern" <<< $( echo $last_part_flags ) && last_part_is_boot="yes"
            # Also test if the mountpoint of the filesystem of the partition
            # contains 'boot' or 'bios' or 'grub' (anywhere case insensitive)
            # because it is not reliable to assume that the boot flag is set in the partition table,
            # cf. https://github.com/rear/rear/commit/91a6d2d11d2d605e7657cbeb95847497b385e148
            grep -E -i "$egrep_pattern" <<< $( echo $last_part_filesystem_mountpoint ) && last_part_is_boot="yes"
            if is_true "$last_part_is_boot" ; then
                last_part_is_resizeable="no"
                Log "Last partition $last_part_dev not resizeable (used during boot)"
            fi
        fi
        # Do not resize partitions that are used as swap partitions:
        if IsInArray "swap" ${AUTORESIZE_EXCLUDE_PARTITIONS[@]} ; then
            last_part_is_swap=''
            # Do not resize a partition for which an active 'swap' entry exists,
            # cf. https://github.com/rear/rear/issues/71
            grep "^swap $last_part_dev " "$LAYOUT_FILE" && last_part_is_swap="yes"
            # A partition is considered to be used as swap partition
            # when its GPT name or flags contain 'swap' (anywhere case insensitive):
            grep -i 'swap' <<< $( echo $last_part_type ) && last_part_is_swap="yes"
            grep -i 'swap' <<< $( echo $last_part_flags ) && last_part_is_swap="yes"
            if is_true "$last_part_is_swap" ; then
                last_part_is_resizeable="no"
                Log "Last partition $last_part_dev not resizeable (used as swap partition)"
            fi
        fi
        # Do not resize partitions that are used for UEFI:
        if IsInArray "efi" ${AUTORESIZE_EXCLUDE_PARTITIONS[@]} ; then
            last_part_is_efi=''
            # A partition is considered to be used for UEFI
            # when its GPT name or flags contain 'efi' or 'esp' (anywhere case insensitive):
            egrep_pattern='efi|esp'
            grep -E -i "$egrep_pattern" <<< $( echo $last_part_type ) && last_part_is_efi="yes"
            grep -E -i "$egrep_pattern" <<< $( echo $last_part_flags ) && last_part_is_efi="yes"
            # Also test if the mountpoint of the filesystem of the partition
            # contains 'efi' or 'esp' (anywhere case insensitive):
            grep -E -i "$egrep_pattern" <<< $( echo $last_part_filesystem_mountpoint ) && last_part_is_efi="yes"
            if is_true "$last_part_is_efi" ; then
                last_part_is_resizeable="no"
                Log "Last partition $last_part_dev not resizeable (used for UEFI)"
            fi
        fi
    fi

    # Determine the new size of the last partition (with 1 MiB alignment):
    Log "Determining new size for last partition $last_part_dev"
    MiB=$( mathlib_calculate "1024 * 1024" )
    # mathlib_calculate cuts integer remainder so that for a disk of e.g. 12345.67 MiB size new_disk_size_MiB = 12345
    new_disk_size_MiB=$( mathlib_calculate "$new_disk_size / $MiB" )
    # For a disk of 12345.67 MiB size the first_byte_after_last_MiB_on_disk = 12944670720
    first_byte_after_last_MiB_on_disk=$( mathlib_calculate "$new_disk_size_MiB * $MiB" )
    # When last_part_start is e.g. at 12300.00 MiB = at the byte 12897484800
    # then new_last_part_size = 12944670720 - 12897484800 = 45.00 MiB
    # so that on a disk of e.g. 12345.67 MiB size the last 0.67 MiB is left unused (as intended for 1 MiB alignment):
    new_last_part_size=$( mathlib_calculate "$first_byte_after_last_MiB_on_disk - $last_part_start" )
    # Note that new_last_part_size could be zero or negative here (that error condition is tested below).

    # Determine if the last partition actually needs to be increased or shrinked and
    # go on or error out or continue with the next disk depending on the particular case:
    Log "Determining if last partition $last_part_dev actually needs to be increased or shrinked"
    disk_size_difference=$( mathlib_calculate "$new_disk_size - $old_disk_size" )
    if test $disk_size_difference -gt 0 ; then
        # The size of the new disk is bigger than the size of the old disk:
        increase_threshold_difference=$( mathlib_calculate "$old_disk_size / 100 * $AUTOINCREASE_DISK_SIZE_THRESHOLD_PERCENTAGE" )
        if test $disk_size_difference -lt $increase_threshold_difference ; then
            if is_true "$last_part_is_resizeable" ; then
                # Inform the user when last partition cannot be resized regardless of his setting in AUTORESIZE_PARTITIONS:
                LogPrint "Last partition $last_part_dev cannot be resized (new disk less than $AUTOINCREASE_DISK_SIZE_THRESHOLD_PERCENTAGE% bigger)"
            else
                Log "Skip increasing last partition $last_part_dev (new disk less than $AUTOINCREASE_DISK_SIZE_THRESHOLD_PERCENTAGE% bigger)"
            fi
            # Continue with next disk:
            continue
        fi
        if is_false "$last_part_is_resizeable" ; then
            Log "Skip increasing last partition $last_part_dev (not resizeable)"
            # Continue with next disk:
            continue
        fi
        LogPrint "Increasing last partition $last_part_dev up to end of disk (new disk at least $AUTOINCREASE_DISK_SIZE_THRESHOLD_PERCENTAGE% bigger)"
        test $new_last_part_size -ge $last_part_size || BugError "New last partition size $new_last_part_size is not bigger than old size $last_part_size"
    else
        # The size of the new disk is smaller than the size of the old disk:
        max_shrink_difference=$( mathlib_calculate "$old_disk_size / 100 * $AUTOSHRINK_DISK_SIZE_LIMIT_PERCENTAGE" )
        # Currently disk_size_difference is negative but the next test needs its absolute value:
        disk_size_difference=$( mathlib_calculate "0 - $disk_size_difference" )
        test $disk_size_difference -gt $max_shrink_difference || Error "New $disk_device more than $AUTOSHRINK_DISK_SIZE_LIMIT_PERCENTAGE% smaller"
        LogPrint "Shrinking last partition $last_part_dev to end of disk (new disk at most $AUTOSHRINK_DISK_SIZE_LIMIT_PERCENTAGE% smaller)"
        is_false "$last_part_is_resizeable" && Error "Cannot shrink $last_part_dev (non-resizeable partition)"
        is_positive_integer $( mathlib_calculate "$new_last_part_size - $MiB - 1" ) || Error "New last partition size $new_last_part_size less than 1 MiB"
    fi

    # Replace the size value of the last partition by its new size value in LAYOUT_FILE.resized_last_partition:
    sed -r -i "s|^part $disk_device $last_part_size $last_part_start (.+) $last_part_dev\$|part $disk_device $new_last_part_size $last_part_start \1 $last_part_dev|" "$disklayout_resized_last_partition"
    LogPrint "Changed last partition $last_part_dev size from $last_part_size to $new_last_part_size bytes"

done < <( grep "^disk " "$LAYOUT_FILE" )

# Use the new LAYOUT_FILE.resized_last_partition with the resized partitions:
mv "$disklayout_resized_last_partition" "$LAYOUT_FILE"

