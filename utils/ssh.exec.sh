#!/bin/bash
#
# Script to run scripts on the DUT
#

SCRIPT=$1

if [[ ! -f $SCRIPT ]]; then
echo "ERROR @ $HOSTNAME(tester): Script '$1' not found"
exit 1
fi

shift # eat first argument (script name)
ARGS=$@  # pass other arguments to script

echo "INFO @ $HOSTNAME(tester): Running '$SCRIPT' with args '$ARGS' passed on DUT '$DUT_HOST'"



# generate temp filename
TMPFILE=$(mktemp -p ./ -u)

# register traps for when tempfile is over
trap -- "rm -f $TMPFILE" 0
trap -- "exit 2" 1 2 3 15

# generate script to execute
{ cat <<EOBATCH
#!/bin/bash
ssh -o "StrictHostKeyChecking no" -o LogLevel=ERROR -i $DUT_SSH_KEY_FILE root@$DUT_HOST 'bash -s $@' <<'ENDSSH'
#!/bin/bash
unset LANG LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES LC_NUMERIC TZ
export LC_ALL=en_US.UTF-8
$(<$SCRIPT)
ENDSSH
rm -f -- $TMPFILE
EOBATCH

} > $TMPFILE

# execute the script
chmod +x $TMPFILE
$TMPFILE $ARGS
EXIT=$?

echo "INFO @ $HOSTNAME(tester): '$SCRIPT' with args '$ARGS' passed on DUT '$DUT_HOST' exited with $EXIT"

exit $EXIT



