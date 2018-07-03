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
  echo -e "    -i    Instance id [OPTIONAL - if not set, figures out instance that this script is running on]"
  echo -e "    -z    Instance zone [OPTIONAL - if not set, figures out instance that this script is running on]"
  echo -e "    -p    Backup All VMs in specified project - [OPTIONAL - if set, script will find all VMs in a project, -i and -z are ignored]"
  echo -e "    -g    GCloud Logging [OPTIONAL - if set, will use gcloud logging to write to stackdriver, using value as the log_name]"
  echo -e "          Note: gcloud logging writes to original project that VM is in, even if -p is specified"
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
    while getopts ":d:i:z:l:g:p:" o; do
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
        p)
          opt_p=${OPTARG}
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

    if [[ -n $opt_p ]];then
      GCP_PROJ=$opt_p
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
    local ES
    local OUTPUT
    OUTPUT="$(gcloud compute disks list --filter users~$1\$ --format='value(name)' 2>&1)"
    ES=$?
    echo -e "$OUTPUT"
    exit $ES
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

    echo -e "${name}"
}


#
# CREATES SNAPSHOT AND RETURNS OUTPUT
#
# input: ${DISK_NAME}, ${SNAPSHOT_NAME}, ${INSTANCE_ZONE}
#

createSnapshot()
{
    # uncomment next 2 lines to simulate an error
    # echo "Simulated failure"
    # exit 1
    local ES
    local OUTPUT
    OUTPUT="$(gcloud compute disks snapshot $1 --snapshot-names $2 --zone $3 2>&1)"
    ES=$?
    echo -e "$OUTPUT"
    exit $ES

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
    local gcloud_response
    gcloud_response="$(gcloud compute snapshots list --filter="name~'"$1"'" --uri)"
    ES=$?
    if [ $ES -gt 0 ]; then
      logger ERROR "Error getting snapshot list, exiting."
      exit $ES
    fi

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
    local snapshot_datetime
    local ES
    snapshot_datetime="$(gcloud compute snapshots describe $1 | grep "creationTimestamp" | cut -d " " -f 2 | tr -d \')"
    if [ -z "$snapshot_datetime" ]; then
        logger ERROR "Problem getting snapshot creation time for deleting"
        exit 1
    fi
    #  format date
    echo -e "$(date -d ${snapshot_datetime%?????} +%Y%m%d)"

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
    local ES
    local OUTPUT
    OUTPUT="$(gcloud compute snapshots delete $1 -q 2>&1)"
    ES=$?
    echo -e "$OUTPUT"
    exit $ES
}



# Log stuff
# Takes 2 args:
# - Severity (DEFAULT, DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, EMERGENCY)
# - Message
logger()
{
    local datetime="$(date +"%Y-%m-%d %T")"
    if [ -n "$GCLOUD_LOG" ]; then
        gcloud logging write $GCLOUD_LOG "$2" --severity $1 --project $ORIGINAL_PROJECT > /dev/null 2>&1
    fi
    if [ -n "$BACKUP_LOGFILE" ]; then
        echo -e -n "$datetime - $1 - " >> $BACKUP_LOGFILE 2>&1
        echo -e $2 >> $BACKUP_LOGFILE 2>&1
    fi
    if [ -z "$BACKUP_LOGFILE" ] && [ -z "$GCLOUD_LOG" ]; then
        echo -e "$datetime - $1 - $2" 1>&2
    fi

    if [ $1 = "ERROR" ]; then
        HAD_ERROR="yes"
    fi
}


#######################
##                   ##
## WRAPPER FUNCTIONS ##
##                   ##
#######################


createSnapshotWrapper()
{

    # get date time
    DATE_TIME="$(date "+%s")"

    # get the instance name
    INSTANCE_NAME=$(getInstanceName)
    logger INFO "    BACKUP $INSTANCE_NAME"

    # get the instance zone
    INSTANCE_ZONE=$(getInstanceZone)
    logger INFO "    Zone: $INSTANCE_ZONE"

    # get a list of all the devices
    DEVICE_LIST=$(getDeviceList ${INSTANCE_NAME})
    ES=$?
    if [ $ES -gt 0 ]; then
      logger ERROR "Error getting device list, exiting."
      exit $ES
    fi
    if [ -z "$DEVICE_LIST" ]; then
      logger WARNING "Device list was empty, exiting."
      sleep 2
      exit 1
    fi
   
    # Device list log on one line
    logger INFO "    Device List: $(echo $DEVICE_LIST)"

    # create the snapshots
    DEV_NUM=0
    while read DEVICE_NAME
    do
        # create snapshot name
        let DEV_NUM=DEV_NUM+1
        DATE_TIME="$(date "+%s")"
        sleep 1
        
        SNAPSHOT_NAME=$(createSnapshotName ${INSTANCE_NAME} ${DEV_NUM} ${DATE_TIME})

        # create the snapshot
        logger INFO "Running: createSnapshot |${DEVICE_NAME}|${SNAPSHOT_NAME}|${INSTANCE_ZONE}|"
        OUTPUT_SNAPSHOT_CREATION=$(createSnapshot ${DEVICE_NAME} ${SNAPSHOT_NAME} ${INSTANCE_ZONE} 2>&1)
        ES=$?
	if [ $ES -gt 0 ]; then
            # Don't want to exit because other snapshots might work since we could have a list
	    logger ERROR "Error creating snapshot:"
            logger ERROR "$OUTPUT_SNAPSHOT_CREATION"
	else
            logger INFO "$OUTPUT_SNAPSHOT_CREATION"
        fi
    done <<< "${DEVICE_LIST}"
}

deleteSnapshotsWrapper()
{
    # get the deletion date for snapshots
    DELETION_DATE=$(getSnapshotDeletionDate "${OLDER_THAN}")
    logger INFO "Deleting snapshots older than this date: ${DELETION_DATE}"

    # Truncate instance name to 40 chars
    SHORT_INSTANCE_NAME=${INSTANCE_NAME:0:40}
    # get list of snapshots for regex - saved in global array
    getSnapshots "gcs-.*${SHORT_INSTANCE_NAME}-.*"
    ES=$?
    if [ $ES -gt 0 ]; then
      logger ERROR "Error getting snapshot list for deletion, exiting."
      exit $ES
    fi

    # loop through snapshots
    for snapshot in "${SNAPSHOTS[@]}"
    do
        # get created date for snapshot
        SNAPSHOT_CREATED_DATE=$(getSnapshotCreatedDate ${snapshot})
        
        if [ -n "$SNAPSHOT_CREATED_DATE" ]; then
            # check if snapshot needs to be deleted
            DELETION_CHECK=$(checkSnapshotDeletion ${DELETION_DATE} ${SNAPSHOT_CREATED_DATE})

            # delete snapshot
            if [ "${DELETION_CHECK}" -eq "1" ]; then
                OUTPUT_SNAPSHOT_DELETION=$(deleteSnapshot ${snapshot} 2>&1)
                ES=$?
                if [ $ES -gt 0 ]; then
                    logger ERROR "Problem deleting snapshot: $OUTPUT_SNAPSHOT_DELETION"
                else
                    logger INFO "$OUTPUT_SNAPSHOT_DELETION"
                fi
            fi
        fi

    done
}


backupProject()
{
    logger INFO "BACKING UP ALL VMs in this GCP Project: ${GCP_PROJ}"
    local vm_list="$(gcloud compute instances list --format='value(name,zone)' --project ${GCP_PROJ})"
    # Split on new line character
    IFS=$'\n'
    for i in ${vm_list[*]}
    do
        INSTANCE_NAME_OVERRIDE="$(echo ${i} | awk {'print $1'})"
        INSTANCE_ZONE_OVERRIDE="$(echo ${i} | awk {'print $2'})"

        createSnapshotWrapper
        deleteSnapshotsWrapper
        
    done
}





##########################
##                      ##
## RUN SCRIPT FUNCTIONS ##
##                      ##
##########################

# get current GCP Project from gcloud before running script
ORIGINAL_PROJECT=`gcloud config -q get-value project`


# set options from script input / default value
setScriptOptions "$@"

# log time
logger INFO "*****************************************"
logger INFO "Starting Backup script: $0 $@"

# if project is set, run on all VMs
if [ -n "${GCP_PROJ}" ]; then
    # set project and do each VM
    gcloud config -q set project ${GCP_PROJ} > /dev/null 2>&1
    backupProject
    # set default gcp project in gcloud back
    gcloud config -q set project $ORIGINAL_PROJECT > /dev/null 2>&1
else
    # do it for a single VM
    createSnapshotWrapper
    deleteSnapshotsWrapper
fi

# log time
if [ -n "$HAD_ERROR" ]; then
    logger WARNING "Backup script finished with errors"
fi

logger INFO "End of Backup Script"
