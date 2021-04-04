#
# Run application
#
# This assumes the following variables set:
#
# APP		contains the application name
# CMD 		contains the command to run
#
# And the following functions:
#
# runCommand	is called to define CMD
# signalHandler	is called to handle the kill signal
#

CURRENT_DIR=$(dirname "$BASH_SOURCE")

exitHandler() {
    echo "INFO @ $HOSTNAME(DUT): Removing locks"
    rm -f /tmp/testbench.lock/$APP.lock
    rmdir /tmp/testbench.lock
}

stop() {
    filename=$1
        # read the pid
        PID=$( <$filename )
        echo "INFO @ $HOSTNAME(DUT): Testbench lockfile PID: $PID"

        if [[ $PID != ?(-)+([0-9]) ]]; then
           echo "ERROR @ $HOSTNAME(DUT): Could not find valid pid for lockfile: '$filename', giving up"
           return 1
        fi

        # send kill signal to pid
        echo "INFO @ $HOSTNAME(DUT): Killing process with PID: $PID"
        kill $PID #kill -2 pid

        echo "INFO @ $HOSTNAME(DUT): Waiting for process to shut down.."
        # wait for pid to be shut down
        timeout 10 tail --pid=$PID -f /dev/null

        if [[ $? -eq 124 ]]; then # wait for process terminate timed out
            echo "ERROR @ $HOSTNAME(DUT): Could not kill pid: $PID, forcing (kill -9)"
            kill -9 $PID
            timeout 10 tail --pid=$PID -f /dev/null
            if [[ $? -eq 124 ]]; then
                echo "ERROR @ $HOSTNAME(DUT): Could not kill pid: $PID, giving up"
                return 1
            fi
        fi
        echo "INFO @ $HOSTNAME(DUT): Process is shut down"

        # check if lock is also gone
        sleep 1 # to prevent race condition
        if [[ -f $filename ]]; then
            echo "ERROR @ $HOSTNAME(DUT): Process is gone, but lock was not removed, forcing remove of lockfile"
            rm -f $filename
        fi
        echo "INFO @ $HOSTNAME(DUT): Lock is removed"
}

stopAll() {
    # is a testbench app running, then kill it
    if [[ -d /tmp/testbench.lock ]]; then
        for filename in /tmp/testbench.lock/*.lock; do
            if [[ ! -e "$filename" ]]; then continue; fi

            stop $filename
        done
        # also remove testbench.lock if not yet done
        if [[ -d /tmp/testbench.lock ]]; then
            rmdir /tmp/testbench.lock
            if [[ $? -ne 0 ]]; then
                echo "ERROR @ $HOSTNAME(DUT): Could not remove lockdir, giving up"
                return 1
            fi
        fi
    fi
    echo "INFO @ $HOSTNAME(DUT): All applications terminated"
}

waitReady() {
    ARG=$2
    TIMEOUT="${ARG:=5}"

    echo "INFO @ $HOSTNAME(DUT): Waiting for $1 (timeout = $TIMEOUT seconds)"

    i=1; 
    while [[ $i -le $TIMEOUT ]]; do 
        if [ -f /tmp/testbench.lock/$1.lock ]; then
            PID=$( </tmp/testbench.lock/$1.lock )
            echo "INFO @ $HOSTNAME(DUT): Running testbench process PID: $PID"
            if ps -p $PID > /dev/null; then
                echo "INFO @ $HOSTNAME(DUT): Program $1 ready"
	        return 0
            else
                echo "ERROR @ $HOSTNAME(DUT): Pid $PID not active, cleaning up lock"
                stop /tmp/testbench.lock/$1.lock
                return 1
            fi
        fi
        i=$((i+1))
        echo -ne "."
        sleep 1
    done

    echo "ERROR @ $HOSTNAME(DUT): Waitready timed out"
    return 1
}

if  [[ $1 == "stop" ]]; then
    if [[ -f /tmp/testbench.lock/$APP.lock ]]; then
        stop /tmp/testbench.lock/$APP.lock
        exit 0
    else
        echo "ERROR @ $HOSTNAME(DUT): Could not find lockfile of $APP"
        exit 1
    fi
fi

if  [[ $1 == "stopAll" ]]; then
    echo "INFO @ $HOSTNAME(DUT): Terminating all testbench applications.."
    stopAll
    exit $?
fi

if  [[ $1 == "waitReady" ]]; then
    waitReady $APP $2
    exit $?
fi


if [[ $1 != "sync" ]] && [[ $1 != "async" ]]; then
    echo "ERROR @ $HOSTNAME(DUT): First argument should be 'sync' or 'async'"
    exit 1
fi

MODE=$1
shift

# check if this script is running
if [[ -e /tmp/testbench.lock/$APP.lock ]]; then
    APID=$( </tmp/testbench.lock/$APP.lock )
    if ps -p $APID > /dev/null ; then
        # application is allready running
        echo "INFO @ $HOSTNAME(DUT): Desired application is running, nothing to be done"
        exit 0
    fi
    # lock found, but pid is gone, so remove it
    rm -f /tmp/testbench.lock/$APP.lock
fi

# is another  testbench app running
if [[ -d /tmp/testbench.lock ]]; then
    echo "INFO @ $HOSTNAME(DUT): Different application then desired is running, terminating them.."
    stopAll
fi

echo "INFO @ $HOSTNAME(DUT): Starting application: '$APP' with command: '$CMD'"

#set CMD and pass any remaining arguments
runCommand $@

if [[ -z $CMD ]];then
    echo "ERROR @ $HOSTNAME(DUT): CMD not set, nothing to execute"
    echo "ERROR @ $HOSTNAME(DUT): Please define CMD in runCommand() to the command to run"
    exit 1
fi

if [[ $MODE == "async" ]]; then
    echo "INFO @ $HOSTNAME(DUT): Running application with nohub"
    nohup $CMD >/dev/null 2>&1 &
    CURPID=$!
else
    echo "INFO @ $HOSTNAME(DUT): Registered signal traps"
    trap exitHandler EXIT  # remove the lockfile on exit

    $CMD &
    CURPID=$!
fi

# create lock files
mkdir /tmp/testbench.lock
echo $CURPID>/tmp/testbench.lock/$APP.lock

echo "INFO @ $HOSTNAME(DUT): Application started with PID: $CURPID"

if [[ $MODE == "sync" ]]; then
    wait $CURPID
    echo "INFO: Application terminated"
else
    echo $APP
fi

