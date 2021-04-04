#!/bin/bash
#
# APP		contains the application name
# CMD 		contains the command to run
#

APP=bare-kern-iec61850-open-server

runCommand() {
    # argument is interface to listen on
    DIR=/opt/iec61850-open-server
    CMD="$DIR/open_server $1 102 $DIR/cfg/IED2_PTOC.cfg $DIR/cfg/IED2_PTOC.ext L 65002"
}





