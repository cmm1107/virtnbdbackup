if [ -z "$TEST" ]; then
    echo ""
    echo "Missing required test env" >&2
    echo "export TEST=<dir> to run specified tests" >&2
    echo ""
    exit
fi

if [ -z "$TMPDIR" ]; then
    export TMPDIR=$(mktemp -d)
    chmod go+rwx $TMPDIR
fi

load $TEST/config.bash

if [ ! -z $HAS_RAW ] && [ -z $OPT ]; then
    export OPT="--raw"
    echo "Raw disk attached Additional options: $OPT" >&3
fi


setup() {
 aa-teardown >/dev/null
 DISKS=$(virsh -q domblklist ${VM} | awk '{print $1}' | wc -l)
 export DISK_COUNT=$DISKS

}

@test "Setup / download vm image $VM_IMAGE to ${TMPDIR}/" {
    if [ -e ${VM_IMAGE}.gz ]; then
        gunzip -fk ${VM_IMAGE}.gz > ${VM_IMAGE}
    fi
    cp ${VM_IMAGE} ${TMPDIR}
}

@test "Setup: Define and start test VM ${VM}" {
    virsh destroy ${VM} || true
    echo "output = ${output}"
    virsh undefine ${VM} --remove-all-storage --checkpoints-metadata || true
    echo "output = ${output}"
    cp ${VM}/${VM}.xml ${TMPDIR}/
    sed -i "s|__TMPDIR__|${TMPDIR}|g" ${TMPDIR}/${VM}.xml
    run virsh define ${TMPDIR}/${VM}.xml
    echo "output = ${output}"
    run virsh start ${VM}
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    echo "output = ${output}"
}

@test "Error handling: strict mode must change exit code if warning happens during backup" {
    run ../virtnbdbackup -d $VM -l copy --strict -o ${TMPDIR}/strict
    [ "$status" -eq 2 ]
}
@test "Checkpoints: Full backup must remove existing checkpoints" {
    [ -z $INCTEST ] && skip "skipping"
    virsh checkpoint-create-as $VM --name virtnbdbackup.0 > /dev/null
    virsh checkpoint-create-as $VM --name virtnbdbackup.1 > /dev/null
    ../virtnbdbackup -d $VM -l full -o ${TMPDIR}/remove-checkpoints
    run virsh checkpoint-delete $VM --checkpointname virtnbdbackup.1
    [ "$status" -eq 1 ]
    run virsh checkpoint-delete $VM --checkpointname virtnbdbackup.0
    [ "$status" -eq 0 ]
}
@test "Start backup job and nbd endpoint to create reference image" {
    rm -rf $BACKUPSET
    run ../virtnbdbackup -t raw $OPT -d $VM -s -o $BACKUPSET --socketfile ${TMPDIR}/sock
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Create reference backup image using qemu-img convert to $BACKUPSET" {
    for disk in $(virsh -q domblklist ${VM} | awk '{print $1}'); do
        run qemu-img convert -f raw nbd+unix:///${disk}?socket=${TMPDIR}/sock -O raw $QEMU_FILE.${disk}
        echo "output = ${output}"
        [ "$status" -eq 0 ]
    done
}
@test "Stop backup job and nbd endpoint" {
    run ../virtnbdbackup -t raw -d $VM -k -o $BACKUPSET
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Extent: Query extents using qemu tools" {
    rm -rf ${TMPDIR}/extentquery
    run ../virtnbdbackup -q -l copy -d $VM -o ${TMPDIR}/extentquery -p
    echo "output = ${output}"
    [[ "$output" =~ "$EXTENT_OUTPUT1" ]]
    [[ "$output" =~ "$EXTENT_OUTPUT2" ]]
    [[ "$output" =~ "$EXTENT_OUTPUT3" ]]
}
@test "Extent: Query extents using extent handler" {
    rm -rf ${TMPDIR}/extentquery
    run ../virtnbdbackup -l copy -d $VM -o ${TMPDIR}/extentquery -p
    echo "output = ${output}"
    [[ "$output" =~ "$EXTENT_OUTPUT1" ]]
    [[ "$output" =~ "$EXTENT_OUTPUT2" ]]
    [[ "$output" =~ "$EXTENT_OUTPUT3" ]]
}
@test "Backup raw using virtnbdbackup, query extents with extenthandler" {
    rm -rf $BACKUPSET
    run ../virtnbdbackup -l copy $OPT -t raw -d $VM -o $BACKUPSET
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Creating full provisioned" ]]
}
@test "Compare backup image contents against reference image" {
    for disk in $(virsh -q domblklist ${VM} | awk '{print $1}'); do
        echo "Disk:${disk}" >&3
        run cmp -b $QEMU_FILE.${disk} "${BACKUPSET}/${disk}.copy.data"
        echo "output = ${output}"
        [ "$status" -eq 0 ]
    done
}
@test "Backup raw using virtnbdbackup, query extents with qemu-img" {
    rm -rf $BACKUPSET
    run ../virtnbdbackup -l copy -q -t raw -d $VM -o $BACKUPSET
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Compare backup image, extents queried via qemu tools" {
    if [ -z $HAS_RAW ]; then
        for disk in $(virsh -q domblklist ${VM} | awk '{print $1}'); do
            run cmp -b $QEMU_FILE.${disk} "${BACKUPSET}/${disk}.copy.data"
            echo "output = ${output}"
            [ "$status" -eq 0 ]
        done
    else
        run cmp -b $QEMU_FILE.sda "${BACKUPSET}/sda.copy.data"
        echo "output = ${output}"
        [ "$status" -eq 0 ]
    fi
}
@test "Backup in stream format, exclude one disk"  {
    [ $DISK_COUNT -lt 2 ] && skip "vm has only one disk"
    run ../virtnbdbackup -l copy -x sdb -d $VM -o "${BACKUPSET}_exclude"
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Excluding Disks sdb" ]]
    [ ! -e "${BACKUPSET}_exclude/sdb.copy.data" ]
}
@test "Backup in stream format"  {
    rm -rf $BACKUPSET
    run ../virtnbdbackup -l copy -d $VM -o $BACKUPSET
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Backup in stream format, check if multiple writers are used"  {
    [ $DISK_COUNT -lt 2 ] && skip "vm has only one disk"
    rm -rf $BACKUPSET
    run ../virtnbdbackup -l copy -d $VM $OPT -o $BACKUPSET
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Concurrent backup processes: [2]" ]]

    if [ ! -z $HAS_RAW ]; then
        [[ "$output" =~ "Creating full provisioned raw back" ]]
    fi
}
@test "Backup in stream format, limit writer to 1"  {
    [ $DISK_COUNT -lt 2 ] && skip "vm has only one disk"
    rm -rf $BACKUPSET
    run ../virtnbdbackup -l copy $OPT -d $VM -w 1 -o $BACKUPSET
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Concurrent backup processes: [1]" ]]
}
toOut() {
    # for some reason bats likes to hijack stdout which results
    # in data being read into memory  ... helper function works
    # around this issue.
    ../virtnbdbackup -l full -d $VM -i sda -o - > ${TMPDIR}/backup.zip
}
@test "Full Backup in stream format, single disk write to stdout, check zip contents"  {
    rm -f ${TMPDIR}/backup.zip
    export PYTHONUNBUFFERED=True
    run toOut
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    [ -e ${TMPDIR}/backup.zip ]
    unzip -l ${TMPDIR}/backup.zip | grep sda.full.data
    [ "$status" -eq 0 ]
    unzip -l ${TMPDIR}/backup.zip | grep vmconfig.virtnbdbackup
    [ "$status" -eq 0 ]
    unzip -l ${TMPDIR}/backup.zip | grep backup.full..*.log
    [ "$status" -eq 0 ]
    unzip -l ${TMPDIR}/backup.zip | grep "${VM}.cpt"
    [ "$status" -eq 0 ]
    unzip -l ${TMPDIR}/backup.zip | grep checkpoints
    [ "$status" -eq 0 ]
    echo "output = ${output}"
}
@test "Dump metadata information" {
    run ../virtnbdrestore -i $BACKUPSET -a dump -o /dev/null
    echo "output = ${output}"
    [[ "$output" =~ "$DATA_SIZE" ]]
    [[ "$output" =~ "$VIRTUAL_SIZE" ]]
}
@test "Restore stream format"  {
    run ../virtnbdrestore -a restore $OPT -i $BACKUPSET -o $RESTORESET
    echo "output = ${output}"
    [[ "$output" =~ "End of stream" ]]
    [ "$status" -eq 0 ]
}
@test "Convert restored qcow2 image to RAW image, compare with reference image"  {
    if [ -z $HAS_RAW ]; then
        for disk in $(virsh -q domblklist ${VM} | awk '{print $1}'); do
            FILENAME="${VM}-${disk}.qcow2"
            echo $FILENAME >&3
            run qemu-img convert -f qcow2 -O raw $RESTORESET/${FILENAME} $RESTORESET/${disk}.raw
            echo "output = ${output}"
            [ "$status" -eq 0 ]
            run cmp $QEMU_FILE.${disk} $RESTORESET/${disk}.raw
            echo "output = ${output}"
            [ "$status" -eq 0 ]
        done
    else
        # restore includes raw files, must not be converted
        FILENAME="${VM}-sda.qcow2"
        echo $FILENAME >&3
        run qemu-img convert -f qcow2 -O raw $RESTORESET/${FILENAME} $RESTORESET/sda.raw
        echo "output = ${output}"
        [ "$status" -eq 0 ]
        run cmp $QEMU_FILE.sda $RESTORESET/sda.raw
        echo "output = ${output}"
        [ "$status" -eq 0 ]
        run cmp $QEMU_FILE.sdb $RESTORESET/${VM}-sdb.qcow2
        [ "$status" -eq 0 ]
    fi
}

# compression
@test "Backup in stream format: with and without compression, restore both and compare results"  {
    BACKUPSET_COMPRESSED="${TMPDIR}/testset_compressed"

    RESTOREDIR="${TMPDIR}/restore_uncompressed"
    RESTOREDIR_COMPRESSED="${TMPDIR}/restore_compressed"

    rm -rf $BACKUPSET $BACKUPSET_COMPRESSED

    run ../virtnbdbackup -l copy -d $VM -o $BACKUPSET
    echo "output = ${output}"
    [ "$status" -eq 0 ]

    run ../virtnbdbackup -l copy -d $VM -o $BACKUPSET_COMPRESSED --compress
    echo "output = ${output}"
    [ "$status" -eq 0 ]

    run ../virtnbdrestore -a restore -i $BACKUPSET_COMPRESSED -o $RESTOREDIR -n -v
    echo "output = ${output}"
    [ "$status" -eq 0 ]

    run ../virtnbdrestore -a restore -i $BACKUPSET_COMPRESSED -o $RESTOREDIR_COMPRESSED -n -v
    echo "output = ${output}"
    [ "$status" -eq 0 ]

    FILENAME=$(basename ${VM_IMAGE})

    run cmp ${TMPDIR}/restore_uncompressed/${FILENAME} ${TMPDIR}/restore_compressed/${FILENAME}
    echo "output = ${output}"
    [ "$status" -eq 0 ]

    rm -rf $RESTOREDIR $RESTOREDIR_COMPRESSED
}

# test for incremental backup

@test "Incremental Setup: Prepare test for incremental backup" {
    [ -z $INCTEST ] && skip "skipping"
    command -v guestmount || exit 1
    rm -rf ${TMPDIR}/inctest
}
@test "Incremental Backup: incremental backup must fail without any checkpoints" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/inctest
    echo "output = ${output}"
    [ "$status" -eq 1 ]
    rm -rf ${TMPDIR}/inctest
}
@test "Backup: incremental backup must fail if third party checkpoint exists" {
    [ -z $INCTEST ] && skip "skipping"
    run virsh checkpoint-create-as $VM --name "external"
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/ext-checkpoint
    echo "output = ${output}"
    [ "$status" -eq 1 ]
    run virsh checkpoint-delete $VM "external"
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    rm -rf ${TMPDIR}/ext-checkpoint
}
@test "Backup: full backup must fail if third party checkpoint exists" {
    [ -z $INCTEST ] && skip "skipping"
    run virsh checkpoint-create-as $VM --name "external"
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    run ../virtnbdbackup -v -d $VM -l full -o ${TMPDIR}/ext-checkpoint-full
    echo "output = ${output}"
    [ "$status" -eq 1 ]
    run virsh checkpoint-delete $VM "external"
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    rm -rf ${TMPDIR}/ext-checkpoint
}
@test "Backup: create full backup" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l full -o ${TMPDIR}/inctest
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Incremental Setup: destroy VM" {
    [ -z $INCTEST ] && skip "skipping"
    run virsh destroy $VM
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Incremental Setup: mount disk via guestmount and create file" {
    [ -z $INCTEST ] && skip "skipping"
    mkdir -p /empty
    run guestmount -d $VM -m /dev/sda1  /empty/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    echo incfile > /empty/incfile
    run umount /empty/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Incremental Setup: start VM after creating file" {
    [ -z $INCTEST ] && skip "skipping"
    sleep 5 # not sure why..
    run virsh start $VM
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Incremental Backup: create first incremental backup" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/inctest
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Incremental Backup: create second incremental backup" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/inctest
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Incremental Restore: restore data and check if file from incremental backup exists" {
    [ -z $INCTEST ] && skip "skipping"
    rm -rf ${TMPDIR}/RESTOREINC/
    run ../virtnbdrestore -a restore -i ${TMPDIR}/inctest/ -o ${TMPDIR}/RESTOREINC/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    FILENAME=$(basename ${VM_IMAGE})
    run guestmount -a ${TMPDIR}/RESTOREINC/${FILENAME} -m /dev/sda1  /empty
    [ "$status" -eq 0 ]
    echo "output = ${output}"
    [ -e /empty/incfile ]
    run umount /empty
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Incremental Restore: restore data until first incremental backup" {
    [ -z $INCTEST ] && skip "skipping"
    rm -rf ${TMPDIR}/RESTOREINC/
    run ../virtnbdrestore -a restore -i ${TMPDIR}/inctest/ --until virtnbdbackup.1 -o ${TMPDIR}/RESTOREINC/
    [[ "${output}" =~  "Reached checkpoint virtnbdbackup.1" ]]
    echo "output = ${output}"
}
@test "Incremental Restore: restore with --sequence option" {
    [ -z $INCTEST ] && skip "skipping"
    rm -rf ${TMPDIR}/RESTOREINC/
    run ../virtnbdrestore -a restore -i ${TMPDIR}/inctest/ --sequence sda.full.data,sda.inc.virtnbdbackup.1.data -o ${TMPDIR}/SEQUENCE
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    [ -e ${TMPDIR}/SEQUENCE/sda ]
}


# tests for offline incremental backup

@test "Incremental Setup: destroy VM for offline backup" {
    [ -z $INCTEST ] && skip "skipping"
    run virsh destroy $VM
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Incremental Setup: mount offline disk via guestmount and create file" {
    [ -z $INCTEST ] && skip "skipping"
    mkdir -p /empty
    run guestmount -d $VM -m /dev/sda1  /empty/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    echo incfile-offline > /empty/incfile-offline
    run umount /empty/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Wait for things to settle {
    [ -z $GITHUB_JOB ] && skip "on homelab"
    sleep 5
}
@test "Offline Backup: full backup must be switched to copy" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l full -o ${TMPDIR}/offline-full
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    [[ "${output}" =~  "Domain is offline, resetting backup options" ]]
    [ -e "${TMPDIR}/offline-full/sda.copy.data" ]
}
@test "Offline Backup: incremental backup for offline VM" {
    [ -z $INCTEST ] && skip "skipping"
    run virsh destroy $VM
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/inctest
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Restore: restore data and check if file from offline incremental backup exists" {
    [ -z $INCTEST ] && skip "skipping"
    rm -rf ${TMPDIR}/RESTOREINC/
    run ../virtnbdrestore -a restore -i ${TMPDIR}/inctest/ -o ${TMPDIR}/RESTOREINC/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    FILENAME=$(basename ${VM_IMAGE})
    run guestmount -a ${TMPDIR}/RESTOREINC/${FILENAME} -m /dev/sda1  /empty
    [ "$status" -eq 0 ]
    echo "output = ${output}"
    [ -e /empty/incfile ]
    [ -e /empty/incfile-offline ]
    run umount /empty
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    run virsh start $VM
}

# differencial backup

@test "Differencial Setup: Prepare test for differencial backup" {
    [ -z $INCTEST ] && skip "skipping"
    command -v guestmount || exit 1
    rm -rf ${TMPDIR}/difftest
}
@test "Differencial Backup: differencial backup must fail without any checkpoints" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l diff -o ${TMPDIR}/difftest
    echo "output = ${output}"
    [ "$status" -eq 1 ]
    rm -rf ${TMPDIR}/difftest
}
@test "Differencial Backup: create full backup" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l full -o ${TMPDIR}/difftest
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Setup: destroy VM" {
    [ -z $INCTEST ] && skip "skipping"
    run virsh destroy $VM
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Setup: mount disk via guestmount and create file" {
    [ -z $INCTEST ] && skip "skipping"
    mkdir -p /empty
    run guestmount -d $VM -m /dev/sda1  /empty/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    echo difffile1 > /empty/diffile1
    run umount /empty/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Setup: start VM after creating file" {
    [ -z $INCTEST ] && skip "skipping"
    sleep 5 # not sure why..
    run virsh start $VM
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Backup: create first differencial backup" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/difftest
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Setup: destroy VM again" {
    [ -z $INCTEST ] && skip "skipping"
    run virsh destroy $VM
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Setup: mount disk via guestmount and create second file" {
    [ -z $INCTEST ] && skip "skipping"
    mkdir -p /empty
    run guestmount -d $VM -m /dev/sda1  /empty/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    echo difffile2 > /empty/diffile2
    run umount /empty/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Setup: start VM after creating second file" {
    [ -z $INCTEST ] && skip "skipping"
    sleep 5 # not sure why..
    run virsh start $VM
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Backup: create second differencial backup" {
    [ -z $INCTEST ] && skip "skipping"
    run ../virtnbdbackup -d $VM -l inc -o ${TMPDIR}/difftest
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}
@test "Differencial Restore: restore data and check if both files from differencial backup exists" {
    [ -z $INCTEST ] && skip "skipping"
    rm -rf ${TMPDIR}/RESTOREINC/
    run ../virtnbdrestore -a restore -i ${TMPDIR}/difftest/ -o ${TMPDIR}/RESTOREDIFF/
    echo "output = ${output}"
    [ "$status" -eq 0 ]
    FILENAME=$(basename ${VM_IMAGE})
    run guestmount -a ${TMPDIR}/RESTOREDIFF/${FILENAME} -m /dev/sda1  /empty
    [ "$status" -eq 0 ]
    echo "output = ${output}"
    [ -e /empty/diffile1 ]
    [ -e /empty/diffile2 ]
    run umount /empty
    echo "output = ${output}"
    [ "$status" -eq 0 ]
}


@test "Map: Map full backup to nbd block device, check device size and partitions" {
    [ -f /.dockerenv ] && skip "wont work inside docker image"
    [ -z $MAPTEST ] && skip "skipping"
    [ ! -z $GITHUB_JOB ] && skip "on github ci"
    modprobe nbd max_partitions=1 || true
    ../virtnbdmap -f ${TMPDIR}/inctest/sda.full.data 3>- &
    PID=$!
    sleep 10
    echo $PID >&3
    run fdisk -l /dev/nbd0
    echo "output = ${output}"
    [[ "${output}" =~  "Disk /dev/nbd0: 50 MiB, 52428800 bytes, 102400 sectors" ]]
    [[ "${output}" =~  "nbd0p1" ]]
    kill -2 $PID
}
