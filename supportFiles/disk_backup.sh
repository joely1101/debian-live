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
    echo "Usage: $0 data_dir /dev/nvme0n1"
}
init_var() 
{
    DATA_DIR="$1"
    TARGET_DEVICE="$2"
    PARTINFO_FILE=$DATA_DIR/partinfo.txt
    PVINFO_FILE=$DATA_DIR/pvinfo.txt
    if [ "$1" == "-h" ] || [ "$1" == "--help" ] || [ "$1" == "help" ]; then
        help
        exit 0
    fi
    #if [ -d $DATA_DIR ]; then
    #    echo "$DATA_DIR exist,please delete it first or rename it"
    #    help
    #    exit 1
    #fi

    if [ ! -b "$TARGET_DEVICE" ]; then
        echo "$TARGET_DEVICE not exist"
        help
        exit 1
    fi
    mkdir -p $DATA_DIR
    DISK_BASENAME=$(basename $TARGET_DEVICE)
}
backup_file()
{
    tmpmnt="/tmp/$DISK_BASENAME"
    mkdir -p $tmpmnt
    while IFS= read -r line; do
        line=$(echo $line | sed 's/^[^a-zA-Z]*//')
        read -r oname type fstype size mount <<< "$line"
        if [ "$type" == "disk" ]; then
            continue
        fi
        echo "$oname $type $fstype $size $mount"
        if [ -z "$oname" ]||[ -z "$type" ]||[ -z "$fstype" ]||[ -z "$size" ]; then
            echo "Error!!! wrong part info:$line "
            exit 99
        fi
        if [ "$type" == "part" ]; then
            if [ "$fstype" == "LVM2_member" ];then
                continue
            fi
            local PART_NUM=${oname##*p}
            local name=${DISK_BASENAME}p${PART_NUM}
            
            if [ ! -b /dev/$name ]; then
                echo "Error!!! /dev/$name not exist"
                exit 99
            fi
            echo "mount $name $tmpmnt and copy files"
            if mount /dev/$name $tmpmnt; then
                echo "copy files to ${DATA_DIR}/${name}.tar.zst"
                tar --zstd -cpf ${DATA_DIR}/${name}.tar.zst -C $tmpmnt .
                umount $tmpmnt
            else
                echo "mount /dev/$name $tmpmnt failed, can NOT copy files"
                exit 99
            fi
        elif [ "$type" == "lvm" ]; then
            name=$(echo $oname | sed 's/^[^a-zA-Z]*//')
            echo "lvm mount $name $mount and copy files"
            if mount /dev/mapper/$name $tmpmnt; then
                echo "copy files to ${DATA_DIR}/${name}.tar.zst"
                tar --zstd -cpf ${DATA_DIR}/${name}.tar.zst -C $tmpmnt .
                umount $tmpmnt
            else
                echo "mount /dev/$name $tmpmnt failed, can NOT copy files"
            fi
        fi
    done < <(cat $PARTINFO_FILE)
}
backup() {
    echo "Backing up partition layout($TARGET_DEVICE) to $DATA_DIR..."
    #set -e
    #enable vg
    while IFS= read -r line; do
        line=$(echo $line | sed 's/^[^a-zA-Z]*//')
        read -r name type fstype <<< "$line"
        name=$(echo $name | sed 's/^[^a-zA-Z]*//')
        if [ -z "$name" ]||[ -z "$type" ]||[ -z "$fstype" ]; then
            continue
        fi
        if [[ "$fstype" == "LVM2_member" ]]; then
            #get vgname
            local VG_NAME=$(pvs -o pv_name,vg_name | grep "$name" | awk '{print $2}')
            if [ -e "$VG_NAME" ]; then
                echo "enable $VG_NAME on /dev/$name"
                vgchange -an "$VG_NAME"
            fi
        fi
    done < <(lsblk -o NAME,TYPE,FSTYPE "$TARGET_DEVICE" | grep LVM2_member)
    lsblk -o NAME,TYPE,FSTYPE,SIZE --bytes "$TARGET_DEVICE" | awk 'NR>1' > "$PARTINFO_FILE"  
    pvs -o pv_name,vg_name > "$PVINFO_FILE"
    backup_file
}

main()
{
    if [ "$#" -ne 2 ]; then
        echo "Error: wrong number of arguments"
        help
        exit 1
    fi
    init_var "$@"
    backup
    echo "=======cat ${PARTINFO_FILE}=========="
    cat $PARTINFO_FILE
    echo "=======cat ${PVINFO_FILE}==========="
    cat $PVINFO_FILE
    ls -al $DATA_DIR
}
main "$@"