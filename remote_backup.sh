#!/bin/bash -e

## Copy remote folder to local folder.
## TL;TR: rsync --delete --exclude $exclusions $remote_host:$remote_path $local_path

# Config parameters

source /usr/local/bin/remote_backup.conf
# VARS (overwrite source values)
##remote_host
##remote_path
##local_path
#exclusions

# Bandwidth
BW=45m

log_file="/var/log/bck/bck_$(date -u '+%F_%T').log"

#### Fail checks ####
# If local and remote size differs more than 10%, backup is ABORTED.
diff_allowed=10
# If local or remote folder size is less than 1TB, backup is ABORTED.
min_size=1000000

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
}

checkSizes() {
  pathLocal="$1"
  pathRemote="$2"
  sizeLocal="$(du -sm ${pathLocal} 2>/dev/null | awk '{print $1}')"
  sizeRemote="$(ssh -q ${remote_host} "du -sm ${pathRemote}" --exclude=${exclusions} 2>/dev/null | awk '{print $1}')"
  echo "Comparing folders size (max allowed diff: ${diff_allowed}%)"
  getAbsDiff ${sizeRemote} ${sizeLocal}
  if [ $absdiff -gt ${diff_allowed} ]; then
    echo "More than ${diff_allowed}% difference between local and remote folders. ABORTING"
    echo "Local folder: ${sizeLocal}"
    echo "Remote folder: ${sizeRemote}"
    echo "Size diff: $absdiff%"
    exit -1
  fi
  echo "Checking folders minimum size (Abort if size less than ${min_size}MB)"
  if ( [ ${sizeLocal} -lt ${min_size} ] || [ ${sizeRemote} -lt ${min_size} ] ) ; then
    echo "Folder size smaller than ${min_size}MB ($((${min_size}/1000))GB). ABORTING"
    echo "Local folder: ${sizeLocal}"
    echo "Remote folder: ${sizeRemote}"
    exit -1
  fi
}

checkPerms() {
  echo "Checking remote folder permisssions"
  path="$1"
  # "cat" artifact added to overwrite return code from find (we want to continue regardless the permission errors).
  unavailable="$(ssh -q ${remote_host} "find ${path} -path ${exclusions} -prune -o -print 2>/dev/stdout >/dev/null |cat")"
  if [ ${#unavailable} != 0 ] ; then
    echo "********************************"
    echo "WARNING: Permission denied errors"
    echo "$unavailable"
    echo "********************************"
  fi
}

backup() {
  echo "Log file:$log_file"
  exc="${exclusions#${remote_path}}" # Remove base path (rsync exclusion is relative to source path)
  rsync -avP --exclude ${exc} --delete -h --progress --stats --bwlimit=$BW ${remote_host}:${remote_path} ${local_path} >> ${log_file} 2>&1
}

echo "Starting checks:"
checkPerms "$remote_path"
checkSizes "$local_path" "$remote_path"

echo "Initiating backup:"
backup

echo "Backup success"

