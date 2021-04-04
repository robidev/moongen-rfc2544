#!/bin/bash
#
# APP		contains the application name
# CMD 		contains the command to run
#

APP=bare-dpdk-smv9-2-publisher

runCommand() {
    # argument is interface to listen on
    pkill ovs-vswitchd 		# kill open vSwitch as it keeps a lock on dpdk
    modprobe uio		# install uio driver
    modprobe igb_uio		# install igb driver for dpdk
    dpdk-devbind -b igb_uio $1	# bind the interface provided as argument for dpdk

    DIR=/usr/bin #/home/user/projects/seapath-test-tools/dpdk/smv9-2-publisher/build
    CMD="$DIR/dpdk_smv9-2-publisher-static -c 2 -n 4 0"
}


