#!/bin/bash
#
# APP		contains the application name
# CMD 		contains the command to run
#

APP=bare-kern-pkt-mirror

runCommand() {
    # argument is interface to listen on
    DIR=/usr/bin
    CMD="$DIR/kern-pkt-mirror $1"
}




