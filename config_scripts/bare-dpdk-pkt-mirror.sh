#!/bin/bash
#
# APP		contains the application name
# CMD 		contains the command to run
#

APP=bare-dpdk-pkt-mirror

runCommand() {
    # argument is interface to listen on
    pkill ovs-vswitchd
    modprobe uio
    modprobe igb_uio
    dpdk-devbind -b igb_uio $1

    DIR=/usr/bin
    CMD="$DIR/dpdk-pkt-mirror -c 2 -n 4 0"
}




