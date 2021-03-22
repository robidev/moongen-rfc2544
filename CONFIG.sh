# location of moongen folder
MOONGEN_PATH="../MoonGen"
# location of moongen executable
MOONGEN=$MOONGEN_PATH/build/MoonGen
# Helper variable for date-string
DATE=$(date +%Y%m%d-%H%M)

# name of output folder, using date string
FOLDER_NAME="testreport_$DATE"

# settings for test device
TESTER_IP="10.0.0.2"
TESTER_INTERFACE_DPDK="07:00.1"

#settings for device under test (DUT)
DUT_NAME="dut2"
DUT_OS="ubuntu"
DUT_HOST="10.0.0.3"
DUT_SSH_KEY_FILE="./dut_key.priv"

DUT_INTERFACE_KERN="enp0s31f6" 	# kernel (ifconfig / ip address show) interface name
DUT_INTERFACE_DPDK="00:1f.6"   	# dpdk (pci address) interface name


## BENCHMARK SETTINGS ##

FRAME_SIZES="128,256,512" #64,1024,1280,1518

# settings regarding the type of rate limiting used. Hardware (hw) Constand Bit Rate (cbr), or more bursty (poison)
# cbr is most predictable and supported. poison might be more realistic, hardware is most reliable
# NOTE: use of hardware rate limiting instead of software is only supported by 10GBe controllers such as X540
# the I210 and I350 do not support hardware rate limiting
USE_RATE_TYPE="cbr"  #options: hw cbr poison
# maximum number of cores used by each benchmark
USE_MAX_CORES=1 #TODO implement option in scripts, currently 1 core used at maximum


TXPORT=0 			# Device to transmit to
RXPORT=0 			# Device to receive from (set to the same device for using 1 NIC)

# Testing that should be inlcuded in this test run
#TEST_INTERPACKET="y"
#TEST_INTERPACKET_DURATION=1 	# <single test duration>

# measure maximum troughput
#TEST_THROUGHPUT="y"
TEST_THROUGHPUT_DURATION=1 	# <single test duration>
TEST_THROUGHPUT_NUM_ITERATIONS=1 # <amount of test iterations>
TEST_THROUGHPUT_RTHS=100   	# <throughput rate threshold>
TEST_THROUGHPUT_MLR=0.1    	# <max throuput loss rate>

# measure link latency at line rate
#TEST_LATENCY="y"
TEST_LATENCY_DURATION=1 	# <single test duration>
TEST_LATENCY_RT=1000   		# <throughput rate> TODO: use rate from throughput

# measure frame-loss for each link speed
#TEST_FRAMELOSS="y"
TEST_FRAMELOSS_DURATION=1 	# <single test duration>
TEST_FRAMELOSS_GRANULARITY=0.5 	# <1/x steps in test (range: 0-1; where 1 means only 1 step, and 0.1 means 10 steps)>

# measure maximum burst length
#TEST_BACKTOBACK="y"
TEST_BACKTOBACK_DURATION=1 	# <single test duration>
TEST_BACKTOBACK_NUM_ITERATIONS=1 # <amount of test iterations>
TEST_BACKTOBACK_BTHS=5 		# <back-to-back frame threshold>


#TEST_IEC61850="y"
#TEST_IEC61850_DURATION=1 	# <single test duration>

# set to generate report
GENERATE_REPORT="y"

# Final setting to indicate all variables have been loaded
TESTBENCH_CONFIGURED="y"