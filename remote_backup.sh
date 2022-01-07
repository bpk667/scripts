#!/bin/bash -e

## Copy remote folder to local folder.
## TL;TR: rsync --delete --exclude $exclusions $remote_host:$remote_path $local_path


# Config parameters
source /usr/local/bin/remote_backup.conf

# VARS (overwrite .conf file values)
##remote_host=remotehost.com
##remote_path=/mnt/nfs/data/
##local_path=/mnt/data_bck/
#exclusions=/mnt/nfs/data/excluded/
#address=root@localhost

# Max. Bandwidth
BW=45m

#### Fail checks ####
# If local and remote size differs more than 10%, backup is ABORTED.
diff_allowed=10
# If local or remote folder size is less than 1TB, backup is ABORTED.
min_size=1000000


log_file="/var/log/bck/bck_$(date -u '+%F_%T').log"

sendEmail() {
	SUBJECT="$1"
  BODY="$2"
  if [[ "$SUBJECT" == "Remote backup OK" ]] ; then
    LOGSIZE="$(wc -l ${log_file} | awk '{print $1}')"
    BODY=$'Remote backup completed.\n\n'
    if [ $LOGSIZE -gt 100 ] ; then
      BODY=$BODY$'Log is too big. See attachment.\n'
    else
      BODY=$BODY$"$(cat ${log_file})"
    fi
    echo "$BODY" | mail -s "$SUBJECT" -A ${log_file} $address
  else
    echo "$BODY" | mail -s "$SUBJECT" $address
  fi
}

getAbsDiff() {
  if [ $1 -gt $2 ] ; then
    bigger=$1
    smaller=$2
  else
    bigger=$2
    smaller=$1
  fi
  diff_percent="$(echo "100 - 100/${bigger}*${smaller}" |bc -l)" # Absolute number: 100 - ABS(diff_percent)
  absdiff=${diff_percent//.*} # Removing decimals
  [ -z "$absdiff" ] && absdiff=0
}

checkSizes() {
  pathLocal="$1"
  pathRemote="$2"
  sizeLocal="$(du -sm ${pathLocal} 2>/dev/null | awk '{print $1}')"
  sizeRemote="$(ssh -q ${remote_host} "du -sm ${pathRemote}" --exclude=${exclusions} 2>/dev/null | awk '{print $1}')"
  echo "Comparing folders size (max allowed diff: ${diff_allowed}%)"
  getAbsDiff ${sizeRemote} ${sizeLocal}
  if [ $absdiff -gt ${diff_allowed} ]; then
    BODY="More than ${diff_allowed}% difference between local and remote folders. ABORTING."$'\n\n'
    BODY=$BODY$"Local folder: ${sizeLocal}"$'\n\n'
    BODY=$BODY$"Remote folder: ${sizeRemote}"$'\n\n'
    BODY=$BODY$"Size diff: $absdiff%"
    echo "$BODY"
    sendEmail "Remote backup error: folders differ more than $diff_allowed" "$BODY"
    exit -1
  fi
  echo "Checking folders minimum size (Abort if size less than ${min_size}MB)"
  if ( [ ${sizeLocal} -lt ${min_size} ] || [ ${sizeRemote} -lt ${min_size} ] ) ; then
    BODY="Folder size smaller than ${min_size}MB ($((${min_size}/1000))GB). ABORTING."$'\n\n'
    BODY=$BODY$"Local folder: ${sizeLocal}MB"$'\n\n'
    BODY=$BODY$"Remote folder: ${sizeRemote}MB"$'\n\n'
    echo "$BODY"
    sendEmail "Remote backup error: folder size less than $min_size" "$BODY"
    exit -1
  fi
}

checkPerms() {
  echo "Checking remote folder permisssions"
  path="$1"
  # "cat" artifact added to overwrite return code from find (we want to continue regardless the permission errors).
  unavailable="$(ssh -q ${remote_host} "find ${path} -path ${exclusions} -prune -o -print 2>/dev/stdout >/dev/null |cat")"
  if [ ${#unavailable} != 0 ] ; then
    BODY="*********************************"$'\n'
    BODY=$BODY$"WARNING: Permission denied errors:"$'\n\n'
    BODY=$BODY$"$unavailable"$'\n\n'
    BODY=$BODY$"*********************************"$'\n\n'
    sendEmail "Remote backup WARNING: Some files were not copied" "$BODY"
  fi
}

backup() {
  echo "Log file:$log_file"
  exc="${exclusions#${remote_path}}" # Remove base path (rsync exclusion is relative to source path)
  rsync -avP --exclude ${exc} --delete -h --progress --stats --bwlimit=$BW ${remote_host}:${remote_path} ${local_path} >> ${log_file} 2>&1
  sendEmail "Remote backup OK"
  echo "Backup success"
}

echo "Starting checks:"
checkPerms "$remote_path"
checkSizes "$local_path" "$remote_path"

echo "Initiating backup:"
backup

