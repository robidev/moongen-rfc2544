

# Prerequisites #

## LaTex for report generation:
`$ sudo apt install texlive texlive-latex-extra`

## MoonGen 
`$ git clone https://github.com/emmericp/MoonGen.git`
(used version: 525d991, on Aug 9, 2020, https://github.com/emmericp/MoonGen/commit/525d9917c98a4760db72bb733cf6ad30550d6669)
`$ cd MoonGen`
`$ ./build`


# Network card support #

list of DPDK supported intel chipsets:
http://core.dpdk.org/supported/nics/intel/


## Network requirement of system running test

The script uses ptp packets for enabling the hardware-timestamping of the NIC.
It is therefore important for the chipset to support IEE1588 (also called PTP)

within PTP there are 2 flavors: LAN Ethernet based PTP(eth-ptp) and routable UDP based PTP(udp-ptp)

the original scripts utilized an X540 chipset (ixgbe driver), with udp-ptp packets
the seapath test setup uses an I350 chipset (igb driver), with eth-ptp packets

only 10Gbe cards (such as the X540) can perform udp-packet ptp timestamping
the I350 (and 82580) are not able to perform udp-packet ptp timestamping, 
but are able to perform hardware timestamping of all received packets by prepending the timestamp to the packet.
other network cards work by writing the timestamp in the buffer on transmission/reception.
this means that after sending a packet, the buffer needs to be re-read, 
to retrieve the timestamp of a transmitted packet before sending the next packet.


## Network requirement of the DUT

The Device Under Test (DUT) will need to have 2 interfaces at minimum. One for control and one for testing.
Part of the tests use DPDK technology on the DUT, so those will need to have a NIC that supports DPDK


# Test setup #

- ensure ssh key is provided, and configured
- ensure seapath image with test tools is used on DUT
- configuring ip of control interface (e.g. Tester:10.0.0.2 <-> DUT:10.0.0.3)
- cable between Tester-Intrerface and DUT-Interface

# Configuring tests #

Modify the config items in; ...
The test takes about xx time. use xx to shorten this


# Running tests #

To initialize the NIC and dpdk on the tester
`sudo ./run_tests.sh setup`

To run the actual test and generate the report
`sudo ./run_tests.sh`
