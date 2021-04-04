#!/bin/bash
#
# Script to run scripts on the DUT
#

if [[ $1 == "stopAll" ]]; then
    echo "Please stop all applications on DUT"
    read -p "and then press enter to continue"
    exit 0
fi

SCRIPT=$1

if [[ ! -f $SCRIPT ]]; then
echo "ERROR @ $HOSTNAME(tester): Script '$1' not found"
exit 1
fi

shift # eat first argument (script name)
ARGS=$@  # pass other arguments to script

source $SCRIPT
runCommand $ARGS

echo "Please run APP:$APP on DUT" 
echo ""
echo "Command to run: $CMD"
echo ""
read -p "and then press enter when ready"

exit $EXIT



