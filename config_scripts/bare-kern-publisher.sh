#!/bin/bash
#
# APP		contains the application name
# CMD 		contains the command to run
#

APP=bare-kern-smv9-2-publisher

runCommand() {
    # argument is interface to listen on
    DIR=/usr/bin #/home/user/projects/seapath-test-tools/kernel/smv9-2-publisher/build
    CMD="$DIR/kern-smv9-2-publisher $1"
}


