#!/bin/bash
#
# APP		contains the application name
# CMD 		contains the command to run
#

APP=bare-dpdk-iec61850-open-server

runCommand() {
    # argument is interface to listen on
    pkill ovs-vswitchd
    modprobe uio
    modprobe igb_uio
    dpdk-devbind -b igb_uio $1

    DIR=/opt/iec61850_open_server-dpdk
    CMD="$DIR/open_server-dpdk 0 102 $DIR/cfg/IED2_PTOC.cfg $DIR/cfg/IED2_PTOC.ext L 65002"
}





