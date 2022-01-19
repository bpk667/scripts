#!/bin/bash -eu

HDD="/dev/sdb"
att=188 # S.M.A.R.T. attribute. 188: Command Timeout.
ds=0 # Desired state
address="root"
refFile="$(readlink -f ../)/smart_state"

isRoot () {
  # Make sure only root can run our script
  if [ $(id -u) -ne 0 ]; then
    echo "$(basename $0) This script must be run as root"
    exit 1
  fi
}

validateNumber () {
  num="$1"
  regex='^[0-9]+$'
  if ! [[ $num =~ $regex ]] ; then
       echo "ERROR: Not a number"
       exit 1
  fi
}

sendEmail() {
	SUBJECT="$1"
  BODY="$2"
  echo "$BODY" | mail -s "$SUBJECT" $address
}

getCurrentState () {
  cs="$(smartctl -d sat -a "$HDD"  |awk -e '/^'${att}' / {print $10}')"
  validateNumber $cs
}

getLatestReference () {
  if [ -f "$refFile" ] ; then
    lastReg="$(tail -n1 $refFile)"
    lastState="${lastReg#*${att}:}"
    validateNumber $lastState
  else
    echo "First time."
    lastState=0
  fi
}

updateRefFile () {
  status="$1"
  echo "[$(date -u '+%F %T')] SMART ID $att: $status" |tee -a $refFile
}

compare () {
  if [ "$1" != "$2" ] ; then
    SUBJ="SMART status changed. Old value $2 - New value $1"
    echo "$SUBJ"
    sendEmail "$SUBJ" "See $refFile for more information"
  else
    echo "SMART status stable. Disk $HDD - ID $att Value: $1"
  fi
}

isRoot
getCurrentState
getLatestReference
updateRefFile $cs
compare $cs $lastState

