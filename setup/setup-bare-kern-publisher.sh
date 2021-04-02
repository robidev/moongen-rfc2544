#!/bin/bash

APP=bare-kern-publisher

DIR=/home/user/projects/seapath-test-tools/kernel/smv9-2-publisher/build  #/usr/bin
CMD="$DIR/kern-smv9-2-publisher $1"
# argument is interface to listen on

signalHandler() {
    echo 'INFO @ $HOSTNAME(DUT) Shutdown signal received. exiting..'
    kill $CURPID
    exit 0
}

exitHandler() {
    rm -rf /tmp/testbench.lock
    rm -rf /tmp/$APP.lock
}


# check if this script is running
if [[ -e /tmp/$APP.lock ]]; then
    # application is allready running
    echo "INFO @ $HOSTNAME(DUT): Desired application is running, nothing to be done"
    exit 0
fi

# is another  testbench app running
if [[ -f /tmp/testbench.lock ]]; then
    echo "INFO @ $HOSTNAME(DUT): Different application then desired is running"
    # read the pid
    PID=$( </tmp/testbench.lock )
    echo "INFO @ $HOSTNAME(DUT): Running testbench process PID: $PID"

    # send kill signal to script
    echo "INFO @ $HOSTNAME(DUT): Killing process with PID: $PID"
    kill -2 $PID

    echo "INFO @ $HOSTNAME(DUT): Waiting for process to shut down.."
    # wait for pid to be shut down
    timeout 10 tail --pid=$PID -f /dev/null

    if [[ $? -eq 124 ]]; then # wait for process terminate timed out
        echo "ERROR @ $HOSTNAME(DUT): Could not shut down process, giving up"
        exit 1
    fi
    echo "INFO @ $HOSTNAME(DUT): Process is shut down"
    # check if lock is also gone
    if [[ -f /tmp/testbench.lock ]]; then
        echo "ERROR @ $HOSTNAME(DUT): Process is gone, but lock was not removed, giving up"
        exit 1
    fi
    echo "INFO @ $HOSTNAME(DUT): Lock is removed"
fi

echo "INFO @ $HOSTNAME(DUT): Starting application: '$APP' with command: '$CMD'"

trap exitHandler EXIT  # remove the lockfile on exit
trap signalHandler SIGINT

$CMD &
CURPID=$!

# create lock files
touch /tmp/$APP.lock
echo $$>/tmp/testbench.lock

echo "INFO @ $HOSTNAME(DUT): Application started with PID: $CURPID"

wait $CURPID

echo "INFO: Application terminated"

