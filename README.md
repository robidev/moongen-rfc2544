

# Prerequisites #

## MoonGen 

### Dependencies of MoonGen

* gcc >= 4.8
* make
* cmake
* libnuma-dev
* kernel headers (for the DPDK igb-uio driver)
* lspci (for `dpdk-devbind.py`)
* [additional dependencies](https://github.com/libmoon/libmoon/blob/master/install-mlx.md) for Mellanox NICs

Run the following command to install these on Debian/Ubuntu:  

```
$ sudo apt-get install -y build-essential cmake linux-headers-`uname -r` pciutils libnuma-dev
```


### Installing MoonGen

`~$ git clone https://github.com/emmericp/MoonGen.git`  
(used version: 525d991, on Aug 9, 2020, https://github.com/emmericp/MoonGen/commit/525d9917c98a4760db72bb733cf6ad30550d6669)  
`~$ cd MoonGen`  
`$ ./build.sh`  

## The testBench

### LaTex for report generation:
`$ sudo apt install texlive texlive-latex-extra`  

### The repo itself
For easy set-up, ensure you are in the parent folder, of where MoonGen resides. i.e. if you installed MoonGen in ~/MoonGen then you should be in ~/
`~$ git clone https://github.com/robidev/moongen-rfc2544.git`  
`~$ cd rfc2544`

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

Modify the config items in; CONFIG  
You can there choose the following options:
- set the folder where tests should be stored
- set the DPDK PCI address of the interface the testbench should use
- have the script set up the DUT, automatic via ssh or with manual prompts
- choose the type of technology the DUT should use. current possiblities are kernel or DPDK. More will be added (docker, kvm)
- test frame sizes. 128, 256, 512 are representative for common GOOSE/SMV9-2 packets
- test duration
- test iterations
- load rates
- test report pdf generation from .tex file

The following test can be chosen
- measure maximum troughput
- measure link latency (at full rate or no-load)
- measure frame-loss for each rate
- measure maximum burst length for each frame-size
- measure link inter-arrival-time (at full rate or no load)
- measure full round-trip latency between SMV-9-2 packet and GOOSE trip

# Running tests #

To initialize the NIC and dpdk on the tester  
`sudo ./testbench.sh setup`

To run the actual test and generate the report  
`sudo ./testbench.sh run`
The test-report will be in the main folder where the script was run.
An additional folder is created with all testresult artifacts.

If something goes wrong during test execution, you can restart the current test run with  
`sudo ./testbench.sh retry`  
This will load CONFIG.run, that contains all settings, and keeps track what test executed succesfully.
After a succesful test run, the file will be renamed to CONFIG.log and placed in the testresult folder along all other artifacts.


