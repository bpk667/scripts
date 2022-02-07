#!/bin/bash -eu

## Copy remote folder to local folder (bck_r2l).
## TL;TR: rsync --delete --exclude $exclusions $remote_host:$remote_path $local_path

## Copy encrypted local folder to remote folder (bck_l2r).
## TL;TR: encfs --reverse local_folder encrypt_folder && rsync --delete encrypted_folder remote_host:$remote_folder

# Config parameters
CONFFILE="/usr/local/bin/remote_backup.conf"

if [ -f "$CONFFILE" ] ; then
  source "$CONFFILE" 
else
  echo "ERROR: Missing config file $CONFFILE"
  exit -1
fi

print_help () {
  echo "Help"
}

processArgs(){
  L2R=TRUE  # Backup from localhost (encrypted) to remote
  R2L=TRUE  # Backup from remote to localhost
  RECOVER=FALSE
  for i in $@; do
    case "$i" in 
      "-nol2r")           L2R=FALSE ;;
      "-nor2l")           R2L=FALSE ;;
      "-recover" | "-r")  RECOVER=TRUE ;;
      *)                  echo "ERROR: Unkown parameter." && print_help && exit -1 ;;
    esac
  done
}

sendEmail() {
	SUBJECT="$1"
  BODY="$2"
  if [[ "$SUBJECT" == *"Remote backup job completed"* ]] ; then
    LOGSIZE="$(wc -l ${log_file} | awk '{print $1}')"
    BODY=$"$SUBJECT."$'\n\n'
    if [ $LOGSIZE -gt 100 ] ; then
      BODY=$BODY$'Log is too big. See attachment.'$'\n\n'
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
  if [ -z "$absdiff" ] ; then
    absdiff=0
  fi
}

checkSizes() {
  local -n params=$1
  local pathLocal="${params[local_path]}"
  local pathRemote="${params[remote_path]}"
  local exclusions="${params[exclusions]}"
  local remote_host="${params[remote_host]}"
  sizeLocal="$(du -sm ${pathLocal} 2>/dev/null | awk '{print $1}')"
  sizeRemote="$(ssh -F ${SSH_CONFIG} -q ${remote_host} "du -sm ${pathRemote}" --exclude=${exclusions} 2>/dev/null | awk '{print $1}')"
  echo "Comparing folders size (max allowed diff: ${diff_allowed}%)"
  getAbsDiff ${sizeRemote} ${sizeLocal}
  if [ $absdiff -gt ${diff_allowed} ]; then
    BODY="More than ${diff_allowed}% difference between local and remote folders. ABORTING."$'\n\n'
    BODY=$BODY$"Local folder size (${pathLocal}): ${sizeLocal}"$'\n\n'
    BODY=$BODY$"Remote folder size (${pathRemote}): ${sizeRemote}"$'\n\n'
    BODY=$BODY$"Size diff: $absdiff%"
    echo "$BODY"
    sendEmail "Remote backup error: folders differ more than $diff_allowed %" "$BODY"
    exit -1
  fi
  echo "Checking folders minimum size (Abort if size less than ${min_size}MB)"
  if ( [ ${sizeLocal} -lt ${min_size} ] || [ ${sizeRemote} -lt ${min_size} ] ) ; then
    BODY="Folder size smaller than ${min_size}MB ($((${min_size}/1000))GB). ABORTING."$'\n\n'
    BODY=$BODY$"Local folder (${pathLocal}): ${sizeLocal}MB"$'\n\n'
    BODY=$BODY$"Remote folder (${pathRemote}): ${sizeRemote}MB"$'\n\n'
    echo "$BODY"
    sendEmail "Remote backup error: folder size less than $min_size" "$BODY"
    exit -1
  fi
}

checkPerms() {
  local -n params=$1
  local local_path="${params[local_path]}"
  local remote_path="${params[remote_path]}"
  local exclusions="${params[exclusions]}"
  local remote_host="${params[remote_host]}"
  # "cat" artifact added to overwrite return code from find (we want to continue regardless the permission errors).
  unavailableRemote="$(ssh -F ${SSH_CONFIG} -q ${remote_host} "find ${remote_path} -path ${exclusions} -prune -o -print 2>/dev/stdout >/dev/null |cat")"
  unavailableLocal="$(find ${local_path} -path ${exclusions} -prune -o -print 2>/dev/stdout >/dev/null |cat)"
  if ( [ ${#unavailableRemote} != 0 ] ||  [ ${#unavailableLocal} != 0 ]); then
    BODY="*********************************"$'\n'
    BODY=$BODY$"WARNING: Permission denied errors:"$'\n\n'
    BODY=$BODY$"Remote warnings: $unavailableRemote"$'\n\n'
    BODY=$BODY$"Local warnings: $unavailableLocal"$'\n\n'
    BODY=$BODY$"*********************************"$'\n\n'
    sendEmail "Remote backup WARNING: Some files were not copied" "$BODY"
  fi
}

backup() {
  local -n params=$1
  local local_path="${params[local_path]}"
  local remote_path="${params[remote_path]}"
  local exclusions="${params[exclusions]}"
  local remote_host="${params[remote_host]}"
  exc="${exclusions#${remote_path}}" # Remove base path (rsync exclusion is relative to source path)
  if [[ "$1" == *r2l* ]]; then
    flow=r2l
    log_file="/var/log/bck/bck_r2l_$(date -u '+%F_%T').log"
    echo "Log file:$log_file"
  elif [[ "$1" == *l2r* ]]; then
    flow=l2r
    log_file="/var/log/bck/bck_l2r_$(date -u '+%F_%T').log"
    echo "Log file:$log_file"
  fi
  if [[ "$flow" == "r2l" ]] ; then
    rsync -avP -e "ssh -F ${SSH_CONFIG}" --exclude ${exc} --delete -h --progress --stats --bwlimit=$BW ${remote_host}:${remote_path} ${local_path} >> ${log_file} 2>&1
    SUBJECT="Remote backup job completed successfully. ${remote_host}:${remote_path} -> $local_path"
    echo -e "BACKUP FINISHED. $SUBJECT"
    sendEmail "$SUBJECT" ""
  elif [[ "$flow" == "l2r" ]] ; then
    set +e
    rsync -avP -e "ssh -F ${SSH_CONFIG}" --exclude ${exc} --delete -h --progress --stats --bwlimit=$BW "${local_path}" ${remote_host}:${remote_path}  >> ${log_file} 2>&1
    rsynccode="$?"
    set -e
    if [ "$rsynccode" -ne 0 ]; then
      SUBJECT="Remote backup job completed with WARNINGS. $local_path -> ${remote_host}:${remote_path}"
    else
      SUBJECT="Remote backup job completed successfully. $local_path -> ${remote_host}:${remote_path}"
    fi
    echo -e "BACKUP FINISHED. $SUBJECT"
    sendEmail "$SUBJECT" ""
  else
    echo 'ERROR: associative array must contain "l2r" (local to remote) or "r2l" (remote to local) string to define the direction of the backup'
  fi
}

mountEncPath() {
  # Temporary mount plaintext folder as encrypted folder for backup.
  local -n params=$1
  local decrypted="${params[local_unencrypted]}"
  local encrypted="${params[local_path]}"
  if [[ $(mount |grep -c ${encrypted::-1}) == 0 ]] ; then
    mkdir -p "${encrypted}"
    echo "Mounting encrypted folder ${encrypted}"
    echo ${encfs_pwd} |encfs -c $ENCFS6_CONFIG -o umask=077 -S --reverse "${decrypted}" "${encrypted}"
  fi
}

unmountEncPath() {
  # Unmount encrypted folder
  local -n params=$1
  local encrypted="${params[local_path]}"
  echo "Dismounting encrypted folder ${encrypted}"
  fusermount -u "${encrypted}"
  rmdir "${encrypted}"
}

recoverEncData() {
  tmpsshfs=/tmp/sshfs
  tmp_decrypt=/tmp/decrypted
  mkdir -p ${tmpsshfs} ${tmp_decrypt}

  # mount remote folder
  sshfs ${bck_l2r[remote_host]}:${bck_l2r[remote_path]} ${tmpsshfs}  -o idmap=user -o uid=`id -u` -o gid=`id -g` -o reconnect
  # Decrypt folder
  echo "${encfs_pwd}" | encfs -c $ENCFS6_CONFIG -S ${tmpsshfs} ${tmp_decrypt}
  echo "Remote encrypted data available at ${tmp_decrypt}"
  echo "After finishing, unmount the volumes with the following commands:"
  # Umount temporary folders
  echo "  encfs -u ${tmp_decrypt}"
  echo "  fusermount -u ${tmpsshfs}"
  echo "  rmdir ${tmpsshfs} ${tmp_decrypt}"
  exit
}

processArgs $@

if [[ "$RECOVER" == "TRUE" ]]; then
  recoverEncData
fi

if [[ "$R2L" == "TRUE" ]]; then
  echo "[$(date -u '+%F')] Starting backup from remote to localhost."
  echo "Starting checks:"
  checkPerms bck_r2l
  checkSizes bck_r2l
  echo "Initiating backup:"
  backup bck_r2l 
fi

if [[ "$L2R" == "TRUE" ]]; then
  echo "[$(date -u '+%F')] Starting backup from localhost to remote"
  mountEncPath bck_l2r
  echo "Starting checks:"
  checkPerms bck_l2r
  checkSizes bck_l2r
  echo "Initiating backup:"
  backup bck_l2r 
  unmountEncPath bck_l2r
fi

