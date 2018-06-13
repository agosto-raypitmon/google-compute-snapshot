#!/usr/bin/env bash
export PATH=$PATH:/usr/local/bin/:/usr/bin




###############################
##                           ##
## INITIATE SCRIPT FUNCTIONS ##
##                           ##
##  FUNCTIONS ARE EXECUTED   ##
##   AT BOTTOM OF SCRIPT     ##
##                           ##
###############################


#
# DOCUMENTS ARGUMENTS
#

usage() {
  echo -e "\nUsage: $0 [-d <days>] [-i <gce instance name>] [-z gcp zone] [-g log_name] [-l logfile]" 1>&2
  echo -e "\nOptions:\n"
  echo -e "    -d    Number of days to keep snapshots.  Snapshots older than this number deleted."
  echo -e "          Default if not set: 7 [OPTIONAL]"
  echo -e "    -i    Instance name [OPTIONAL - if not set, figures out instance that this script is running on]"
  echo -e "    -z    Instance zone [OPTIONAL - if not set, figures out instance that this script is running on]"
  echo -e "    -g    GCloud Logging [OPTIONAL - if set, will use gcloud logging to write to stackdriver, using value as the log_name]"
  echo -e "    -l    Log file [OPTIONAL - if set, will write to this logfile using value as the file name]"
  echo -e "    Note: If both -g and -l are not set, it will log to stdout"
  echo -e "\n"
  exit 1
}


#
# GETS SCRIPT OPTIONS AND SETS GLOBAL VAR $OLDER_THAN
#

setScriptOptions()
{
    while getopts ":d:i:z:l:g:" o; do
      case "${o}" in
        d)
          opt_d=${OPTARG}
          ;;
        i)
          opt_i=${OPTARG}
          ;;
        z)
          opt_z=${OPTARG}
          ;;
        l)
          opt_l=${OPTARG}
          ;;
        g)
          opt_g=${OPTARG}
          ;;

        *)
          usage
          ;;
      esac
    done
    shift $((OPTIND-1))

    if [[ -n $opt_d ]];then
      OLDER_THAN=$opt_d
    else
      OLDER_THAN=7
    fi

    if [[ -n $opt_i ]];then
      INSTANCE_NAME_OVERRIDE=$opt_i
    fi

    if [[ -n $opt_z ]];then
      INSTANCE_ZONE_OVERRIDE=$opt_z
    fi

    if [[ -n $opt_l ]];then
      BACKUP_LOGFILE=$opt_l
    fi

    if [[ -n $opt_g ]];then
      GCLOUD_LOG=$opt_g
    fi

}


#
# RETURNS INSTANCE NAME
#

getInstanceName()
{
    if [[ -n $INSTANCE_NAME_OVERRIDE ]]; then
      echo $INSTANCE_NAME_OVERRIDE
    else
      # get the name for this vm
      local instance_name="$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/hostname" -H "Metadata-Flavor: Google")"

      # strip out the instance name from the fullly qualified domain name the google returns
      echo -e "${instance_name%%.*}"
    fi
}


#
# RETURNS INSTANCE ID
#

getInstanceId()
{
  if [[ -n $INSTANCE_NAME_OVERRIDE ]]; then
    local instance_id
    instance_id="$(gcloud compute instances describe ${INSTANCE_NAME_OVERRIDE} --zone ${INSTANCE_ZONE} | grep ^id:)"

    echo $instance_id | cut -d "'" -f 2
  else
    echo -e "$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/id" -H "Metadata-Flavor: Google")"
  fi
}


#
# RETURNS INSTANCE ZONE
#

getInstanceZone()
{
    if [[ -n $INSTANCE_ZONE_OVERRIDE ]]; then
      echo $INSTANCE_ZONE_OVERRIDE
    else
      local instance_zone="$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google")"

      # strip instance zone out of response
      echo -e "${instance_zone##*/}"
    fi
}


#
# RETURNS LIST OF DEVICES
#
# input: ${INSTANCE_NAME}
#

getDeviceList()
{
    echo "$(gcloud compute disks list --filter users~$1 --format='value(name)')"
}


#
# RETURNS SNAPSHOT NAME
#

createSnapshotName()
{

    # new args: ${VM_NAME} ${disknum} ${DATE_TIME}
    # old args: ${DEVICE_NAME} ${INSTANCE_ID} ${DATE_TIME}

    # new snapshot name:
    # gcs-VMNAME-disknum-secondsince

    # truncate vm name to 41 chars to be save
    local name="gcs-${1:0:40}-$2-$3"

    echo -e ${name}
}


#
# CREATES SNAPSHOT AND RETURNS OUTPUT
#
# input: ${DISK_NAME}, ${SNAPSHOT_NAME}, ${INSTANCE_ZONE}
#

createSnapshot()
{
    echo -e "$(gcloud compute disks snapshot $1 --snapshot-names $2 --zone $3 2>&1)"
}


#
# GETS LIST OF SNAPSHOTS AND SETS GLOBAL ARRAY $SNAPSHOTS
#
# input: ${SNAPSHOT_REGEX}
# example usage: getSnapshots "(gcs-.*${INSTANCE_ID}-.*)"
#

getSnapshots()
{
    # create empty array
    SNAPSHOTS=()

    # get list of snapshots from gcloud for this device
    local gcloud_response="$(gcloud compute snapshots list --filter="name~'"$1"'" --uri)"

    # loop through and get snapshot name from URI
    while read line
    do
        # grab snapshot name from full URI
        snapshot="${line##*/}"

        # add snapshot to global array
        SNAPSHOTS+=(${snapshot})

    done <<< "$(echo -e "$gcloud_response")"
}


#
# RETURNS SNAPSHOT CREATED DATE
#
# input: ${SNAPSHOT_NAME}
#

getSnapshotCreatedDate()
{
    local snapshot_datetime="$(gcloud compute snapshots describe $1 | grep "creationTimestamp" | cut -d " " -f 2 | tr -d \')"

    #  format date
    echo -e "$(date -d ${snapshot_datetime%?????} +%Y%m%d)"

    # Previous Method of formatting date, which caused issues with older Centos
    #echo -e "$(date -d ${snapshot_datetime} +%Y%m%d)"
}


#
# RETURNS DELETION DATE FOR ALL SNAPSHOTS
#
# input: ${OLDER_THAN}
#

getSnapshotDeletionDate()
{
    echo -e "$(date -d "-$1 days" +"%Y%m%d")"
}


#
# RETURNS ANSWER FOR WHETHER SNAPSHOT SHOULD BE DELETED
#
# input: ${DELETION_DATE}, ${SNAPSHOT_CREATED_DATE}
#

checkSnapshotDeletion()
{
    if [ $1 -ge $2 ]

        then
            echo -e "1"
        else
            echo -e "2"

    fi
}


#
# DELETES SNAPSHOT
#
# input: ${SNAPSHOT_NAME}
#

deleteSnapshot()
{
    echo -e "$(gcloud compute snapshots delete $1 -q)"
}



# Log stuff
# Takes 2 args:
# - Severity (ERROR, WARN, INFO, DEBUG)
# - Message
logger()
{
    local datetime="$(date +"%Y-%m-%d %T")"
    if [ -n "$GCLOUD_LOG" ]; then
        gcloud logging write $GCLOUD_LOG "$2" --severity $1 > /dev/null 2>&1
    fi
    if [ -n "$BACKUP_LOGFILE" ]; then
        echo -e "$datetime - $1 - $2" >> $BACKUP_LOGFILE 2>&1
    fi
    if [ -z "$BACKUP_LOGFILE" ] && [ -z "$GCLOUD_LOG" ]; then
        echo -e "$datetime - $1 - $2" 1>&2
    fi

}


#######################
##                   ##
## WRAPPER FUNCTIONS ##
##                   ##
#######################


createSnapshotWrapper()
{
    # log time
    logger INFO "Start of createSnapshotWrapper"

    # get date time
    DATE_TIME="$(date "+%s")"

    # get the instance name
    INSTANCE_NAME=$(getInstanceName)
    logger INFO "*****************************************"
    logger INFO "\tBACKUP $INSTANCE_NAME"

    # get the instance zone
    INSTANCE_ZONE=$(getInstanceZone)
    logger INFO "\tZone: $INSTANCE_ZONE"

    # get a list of all the devices
    DEVICE_LIST=$(getDeviceList ${INSTANCE_NAME})

    # Device list show on one line
    logger INFO "\tDevice List: $(echo $DEVICE_LIST)"

    # create the snapshots
    DEV_NUM=0
    echo "${DEVICE_LIST}" | while read DEVICE_NAME
    do
        # create snapshot name
        let DEV_NUM=DEV_NUM+1
        DATE_TIME="$(date "+%s")"
        sleep 1
        
        SNAPSHOT_NAME=$(createSnapshotName ${INSTANCE_NAME} ${DEV_NUM} ${DATE_TIME})

        # create the snapshot
        logger INFO "createSnapshot ${DEVICE_NAME} ${SNAPSHOT_NAME} ${INSTANCE_ZONE}"
        OUTPUT_SNAPSHOT_CREATION=$(createSnapshot ${DEVICE_NAME} ${SNAPSHOT_NAME} ${INSTANCE_ZONE} 2>&1)
        logger INFO "$OUTPUT_SNAPSHOT_CREATION"
    done
}

deleteSnapshotsWrapper()
{
    # log time
    logger INFO "Start of deleteSnapshotsWrapper"

    # get the deletion date for snapshots
    DELETION_DATE=$(getSnapshotDeletionDate "${OLDER_THAN}")

    # Truncate instance name to 40 chars
    SHORT_INSTANCE_NAME=${INSTANCE_NAME:0:40}
    # get list of snapshots for regex - saved in global array
    getSnapshots "gcs-.*${SHORT_INSTANCE_NAME}-.*"

    # loop through snapshots
    for snapshot in "${SNAPSHOTS[@]}"
    do
        # get created date for snapshot
        SNAPSHOT_CREATED_DATE=$(getSnapshotCreatedDate ${snapshot})

        # check if snapshot needs to be deleted
        DELETION_CHECK=$(checkSnapshotDeletion ${DELETION_DATE} ${SNAPSHOT_CREATED_DATE})

        # delete snapshot
        if [ "${DELETION_CHECK}" -eq "1" ]; then
           OUTPUT_SNAPSHOT_DELETION=$(deleteSnapshot ${snapshot})
        fi

    done
}




##########################
##                      ##
## RUN SCRIPT FUNCTIONS ##
##                      ##
##########################


# set options from script input / default value
setScriptOptions "$@"

# log time
logger INFO "Executing script: $0 $@ "

# create snapshot
createSnapshotWrapper

# delete snapshots older than 'x' days
deleteSnapshotsWrapper

# log time
logger INFO "End of Backup Script"
