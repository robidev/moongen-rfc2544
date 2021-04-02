#!/bin/bash

# is a testbench app running
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

echo "INFO @ $HOSTNAME(DUT): All applications terminated"

