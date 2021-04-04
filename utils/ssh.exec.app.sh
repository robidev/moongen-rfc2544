#!/bin/bash
#
# Script to run scripts on the DUT
#
# Arguments:
# script	script to load before run_app.sh
# [..]		any arguments to pass on to run_app.sh
#

SCRIPT=$1

CURRENT_DIR=$(dirname "$BASH_SOURCE")

if [[ ! -f $SCRIPT ]]; then
echo "ERROR @ $HOSTNAME(tester): Script '$1' not found"
exit 1
fi

shift # eat first argument (script name)
ARGS=$@  # pass other arguments to script

echo "INFO @ $HOSTNAME(tester): Running '$SCRIPT' with args '$ARGS' passed on DUT '$CONFIG_DUT_HOST'"



# generate temp filename
TMPFILE=$(mktemp -p ./ -u)

# register traps for when tempfile is over
trap -- "rm -f $TMPFILE" 0
trap -- "exit 2" 1 2 3 15

# generate script to execute
{ cat <<EOBATCH
#!/bin/bash
ssh -o "StrictHostKeyChecking no" -o LogLevel=ERROR -i $CONFIG_DUT_SSH_KEY_FILE root@$CONFIG_DUT_HOST 'bash -s $@' <<'ENDSSH'
#!/bin/bash
unset LANG LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES LC_NUMERIC TZ
export LC_ALL=en_US.UTF-8

$(<$SCRIPT)

$(<$CURRENT_DIR/run_app.sh)

ENDSSH

SSH_RESULT=\$?
rm -f -- $TMPFILE
exit \$SSH_RESULT
EOBATCH

} > $TMPFILE

# execute the script
chmod +x $TMPFILE
$TMPFILE $ARGS
EXIT=$?

echo "INFO @ $HOSTNAME(tester): '$SCRIPT' with args '$ARGS' passed on DUT '$CONFIG_DUT_HOST' exited with $EXIT"

exit $EXIT



