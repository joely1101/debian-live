#!/bin/bash

set -euo pipefail

# Verify root privileges
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root!" >&2
    exit 1
fi

#./partinfo.txt
:<<COMMENT
#######  partinfo.txt
lsblk -o NAME,TYPE,FSTYPE,SIZE --bytes /dev/nvme0n1 | awk 'NR>1'
nvme0n1                         disk             960197124096
├─nvme0n1p1                     part vfat          1073741824
├─nvme0n1p2                     part xfs           1073741824
└─nvme0n1p3                     part LVM2_member   8047191040
  ├─vg00-root                   lvm  xfs           1073741824
  ├─vg00-var_log_audit          lvm  xfs           1073741824
  └─vg00-opt                    lvm  vfat           1073741824
└─nvme0n1p4                     part LVM2_member   8047191040
  ├─vg01-root2                  lvm  ext2           1073741824
  ├─vg01-var2                   lvm  ext3           1073741824
  └─vg01-opt2                   lvm  ext4           1073741824

#####pvinfo.txt
pvs -o pv_name,vg_name | awk 'NR>1'
/dev/nvme0n1p3 vg00
/dev/nvme0n1p4 vg01
COMMENT
help() {
    echo "Example: $0 data_dir /dev/nvme0n1"
}
delete_lvm()
{
    echo "====$1"
    local device=$1
    #/dev/nvme0n1p3
    local VG=$(pvs --noheadings $device | awk '{ print $2 }')
    echo "VG=$VG"
    if [ -z "$VG" ]; then
        return
    fi
    vgchange -an $VG
    vgremove -f $VG
    pvremove -f "$device"
}
init_var() 
{
    DATA_DIR=$1
    TARGET_DEVICE=$2
    PARTINFO_FILE=$DATA_DIR/partinfo.txt
    PVINFO_FILE=$DATA_DIR/pvinfo.txt
    if [ "$1" == "-h" ] || [ "$1" == "--help" ] || [ "$1" == "help" ]; then
        help
        exit 0
    fi
    if [ ! -d "$DATA_DIR" ] || [ ! -b "$TARGET_DEVICE" ]; then
        echo "$DATA_DIR or $TARGET_DEVICE not exist"
        help
        exit 1
    fi
    
    if [ ! -f "$PARTINFO_FILE" ] || [ ! -f "$PVINFO_FILE" ]; then
        echo "$PARTINFO_FILE or $PVINFO_FILE not exist, $DATA_DIR is not a valid backup dir"
        help
        exit 1
    fi
    LSBLK_OUTPUT=$(cat $PARTINFO_FILE) 
    # Wipe existing partitions
    while IFS=" " read -r pv_name vg_name; do
        pv_name=$(echo "$pv_name" | xargs)
        vg_name=$(echo "$vg_name" | xargs)
        echo "=========>$pv_name,$vg_name,"
        if [ -n "$vg_name" ]; then
            echo "vgchange -an $vg_name"
            vgchange -an $vg_name
            vgremove -f $vg_name
        fi
        if [ -n "$pv_name" ]; then
            echo "pvremove -f $pv_name"
            pvremove -f $pv_name
        fi

    done < <(pvs -o pv_name,vg_name|grep $TARGET_DEVICE)
}
get_disk_name() {
    DISK_NAME=$(grep disk $PARTINFO_FILE | awk '{print $1}')
    echo "$DISK_NAME"
}
get_vg_name() {
    local PART_NUM=${1##*p}
    local lv_name="p${PART_NUM}"
    local VG_NAME=$(grep "$lv_name" "$PVINFO_FILE" | awk '{print $2}'| tr -d '\r')
    echo "$VG_NAME"
}
partition_init() 
{
    echo "Wiping existing partitions..."
    wipefs -a "$TARGET_DEVICE"
    partprobe "$TARGET_DEVICE"
    # Create new GPT partition table
    echo "Creating GPT partition table..."
    parted -s "$TARGET_DEVICE" mklabel gpt

}
partition_partition()
{
    # Recreate partitions
    echo "Recreating partitions..."
    START=1
    while IFS= read -r line; do
        line=$(echo $line | sed 's/^[^a-zA-Z]*//')
        echo " lllll $line"
        read -r NAME TYPE FSTYPE SIZE_BYTES <<< "$line"
        echo "===============xxx================ $NAME $TYPE $FSTYPE $SIZE_BYTES"
        SIZE_MB=$((SIZE_BYTES / 1024 / 1024))

        if [[ "$TYPE" != "part" ]]; then
            continue
        fi
        PART_NUM=${NAME##*p}
        END=$((START + SIZE_MB))
        echo "Creating partition $NAME (${SIZE_MB}MB, $FSTYPE)..."
        echo "parted -s $TARGET_DEVICE mkpart primary ${START}MiB ${END}MiB"
        parted -s "$TARGET_DEVICE" mkpart primary "${START}MiB" "${END}MiB"
        START=$END
        partprobe "$TARGET_DEVICE"

        if [[ "$FSTYPE" == "LVM2_member" ]]; then
            PART_NUM=${NAME##*p}
            local PART_PATH="${TARGET_DEVICE}p${PART_NUM}"
            pvcreate -ff --yes "$PART_PATH"
            VGNAME=$(get_vg_name "$NAME")
            echo "vgcreate $VGNAME $PART_PATH"
            vgcreate "$VGNAME" "$PART_PATH"
            vgchange -ay "$VGNAME"
        fi
    done <<< "$LSBLK_OUTPUT"
    partprobe "$TARGET_DEVICE"

    while IFS= read -r line; do
        line=$(echo $line | sed 's/^[^a-zA-Z]*//')
        read -r NAME TYPE FSTYPE SIZE_BYTES <<< "$line"
        SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
        if [[ "$TYPE" == "part" ]]; then
            PART_NUM=${NAME##*p}
            PART_PATH="${TARGET_DEVICE}p${PART_NUM}"
            case "$FSTYPE" in
                "vfat")
                    echo "mkfs.vfat -F32 $PART_PATH"
                    mkfs.vfat -F32 "$PART_PATH"
                    ;;
                "xfs")
                    echo "mkfs.xfs -f $PART_PATH"
                    mkfs.xfs -f "$PART_PATH"
                    ;;
                "ext2"|"ext3"|"ext4")
                    echo "mkfs.$FSTYPE -f $PART_PATH"
                    mkfs."$FSTYPE" -F "$PART_PATH"
                    ;;
            esac
        fi
    done <<< "$LSBLK_OUTPUT"
    partprobe "$TARGET_DEVICE"
}
partition_lvm()
{
    echo "Creating LVM logical volumes..."
    while IFS= read -r line; do
        line=$(echo $line | sed 's/^[^a-zA-Z]*//')
        read -r NAME TYPE FSTYPE SIZE_BYTES <<< "$line"
        SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
        if [[ "$TYPE" == "lvm" ]]; then
            if [[ $NAME =~ ([a-zA-Z0-9]+)-([a-zA-Z0-9_]+) ]]; then 
                VG_NAME=${BASH_REMATCH[1]};
                LV_NAME=${BASH_REMATCH[2]}
            fi
            echo "Creating logical volume $LV_NAME (${SIZE_MB}MB) in VG $VG_NAME..."
            echo "lvcreate -L ${SIZE_MB}M -n $LV_NAME $VG_NAME"
            lvcreate -L "${SIZE_MB}M" -n "$LV_NAME" "$VG_NAME" -y
            case "$FSTYPE" in
                "vfat")
                    echo "mkfs.vfat -F32 /dev/$VG_NAME/$LV_NAME"
                    mkfs.vfat -F32 "/dev/$VG_NAME/$LV_NAME"
                    ;;
                "xfs")
                    echo "mkfs.xfs -f /dev/$VG_NAME/$LV_NAME"   
                    mkfs.xfs -f "/dev/$VG_NAME/$LV_NAME"
                    ;;
                "ext2"|"ext3"|"ext4")
                    echo "mkfs.$FSTYPE -F /dev/$VG_NAME/$LV_NAME"
                    mkfs."$FSTYPE" -F "/dev/$VG_NAME/$LV_NAME"
                    ;;
                *)
                    echo "Unknown file system type: $FSTYPE"
                    ;;
            esac
        fi
    done <<< "$LSBLK_OUTPUT"
}

main()
{
    vgchange -an
    init_var $@
    partition_init
    partition_partition
    partition_lvm
}
main $@
echo "Operation completed successfully!"
lsblk -o NAME,TYPE,FSTYPE,SIZE "$TARGET_DEVICE"