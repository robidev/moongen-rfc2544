#!/bin/bash
#
# Test bench for the seapath project
#
# This test bench will perform various tests to check the real-time performance of the seapath project
#
# 

# we need sudo rights for running moongen
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root (i.e. sudo $0)"
    exit 1
fi


# check for options. prevent the test from running accidentally
if [[ $1 != "setup" ]] && [[ $1 != "run" ]] && [[ $1 != "retry" ]]; then
    echo "Invalid, or unrecognised option in: $0 $@"
    echo ""
    echo " --- SEAPATH Test Bench ---"
    echo ""
    echo "This tool will run a set of test scripts that will test the performance of the"
    echo "SEAPATH image. It requires 2 ethernet links between the Device Under Test(DUT)"
    echo "and the tester(this machine). One link is used for control, and the other for "
    echo "test-traffic. The configuration is in CONFIG"
    echo ""
    echo "Valid options are:"
    echo " $0 setup - setup the test system. only needs to be run once"
    echo " $0 run   - run the test, using 'CONFIG' file in the same folder"
    echo " $0 retry - run the test, using the active 'CONFIG.run' file"
    echo ""
    exit 0
fi


# directory the script is in
CURRENT_DIR=$(dirname "$BASH_SOURCE")

#
# load configuration from CONFIG.sh or an active run with CONFIG.run
#
if [[ $1 == "retry" ]]; then
    # check for config file
    if [[ -f "$CURRENT_DIR/CONFIG.run" ]]; then
        source "$CURRENT_DIR/CONFIG.run"
        # check if config is correctly sourced
        if [[ -z "$TESTBENCH_CONFIGURED_RUN" ]]; then
            echo "ERROR: Invalid CONFIG.run in $CURRENT_DIR"
            exit 1
        fi
        echo "Config settings are loaded from $CURRENT_DIR/CONFIG.run"
        echo "Test run will be continued where previously left off"
    else
        echo "ERROR: Could not find CONFIG.run in $CURRENT_DIR"
        exit 1
    fi
else
    # check for config file
    if [[ -f "$CURRENT_DIR/CONFIG" ]]; then
        source "$CURRENT_DIR/CONFIG"
        # check if config is correctly sourced
        if [[ -z "$TESTBENCH_CONFIGURED" ]]; then
            echo "ERROR: Invalid CONFIG in $CURRENT_DIR"
            exit 1
        fi
        echo "Config settings are loaded from $CURRENT_DIR/CONFIG"
    else
        echo "ERROR: Could not find CONFIG in $CURRENT_DIR"
        exit 1
    fi
fi

#
# Setup the test by installing the drivers, binding the interface and allocating hugepages
#

if [[ $1 == "setup" ]]; then
    # load dpdk drivers
    echo "Installing uio driver"
    modprobe uio
    if [ $? -ne 0 ]; then
	echo "ERROR: Installing uio driver"
	exit 1
    fi

    echo "Installing igb_uio driver"
    (lsmod | grep igb_uio > /dev/null) || insmod $MOONGEN_PATH/libmoon/deps/dpdk/x86_64-native-linuxapp-gcc/kmod/igb_uio.ko
    if [ $? -ne 0 ]; then
	echo "ERROR: Installing igb_uio driver"
	exit 1
    fi

    # setup testing interface
    echo "Binding interface: $TESTER_INTERFACE_DPDK"
    $MOONGEN_PATH/libmoon/deps/dpdk/usertools/dpdk-devbind.py -b igb_uio $TESTER_INTERFACE_DPDK
    if [ $? -ne 0 ]; then
	echo "ERROR: Binding interface: $TESTER_INTERFACE_DPDK"
	exit 1
    fi
    # setup hugetablefs
    echo "Setting up hugetlbfs"
    $MOONGEN_PATH/setup-hugetlbfs.sh
    if [ $? -ne 0 ]; then
	echo "ERROR: Setting up hugetlbfs"
	exit 1
    fi
    echo "Setup finished succesful. You can start the test by running $0 run"
    exit 0
fi


#
# The DUT config functions
#

function config_DUT () { # TODO: TEST IT
    # start program "$1" on DUT
    ssh -o UserKnownHostsFile=/dev/null -i $DUT_SSH_KEY_FILE root@$DUT_HOST $1 &
    return $! # return pid of remote forked process
}

function unconfig_DUT () { # TODO: TEST IT
    # kill program PID "$1" on DUT
    ssh -o UserKnownHostsFile=/dev/null -i $DUT_SSH_KEY_FILE root@$DUT_HOST kill $1
    return $? # return result
}


# check if no config.run is loaded, that will be resumed
if [[ -z "$TESTBENCH_CONFIGURED_RUN" ]]; then
    cp "$CURRENT_DIR/CONFIG" "$CURRENT_DIR/CONFIG.run"
    echo "# " 				  >> "$CURRENT_DIR/CONFIG.run"
    echo "# Progress:"	 		  >> "$CURRENT_DIR/CONFIG.run"
    echo "# " 				  >> "$CURRENT_DIR/CONFIG.run"
    echo "TESTBENCH_CONFIGURED_RUN=\"y\"" >> "$CURRENT_DIR/CONFIG.run"
    echo "DATE=\"$DATE\""                 >> "$CURRENT_DIR/CONFIG.run"
    echo "FOLDER_NAME=\"$FOLDER_NAME\""   >> "$CURRENT_DIR/CONFIG.run"

    echo "progress is stored in $CURRENT_DIR/CONFIG.run"
fi


#
# The actual tests
#
echo ""
echo "-- Starting test --"
echo ""

# Start the latex file with DUT description
if [[ -z "$TEST_START" ]]; then
    echo ""
    echo "-- Creating tex file --"
    echo ""
    $MOONGEN ./benchmarks/start.lua $DUT_NAME $DUT_OS -f $FOLDER_NAME
    if [ $? -ne 0 ]; then
        echo "ERROR: MoonGen script not executed succesfully"
        exit 1
    else
	chmod 777 $FOLDER_NAME ## convenience so we are allowed to delete it as normal user
        echo 'TEST_START="y"' >> "$CURRENT_DIR/CONFIG.run"
    fi
fi

# run tests
if [[ -n "$TEST_THROUGHPUT" ]]; then
    echo ""
    echo "-- Starting throughput test --"
    echo ""
    $MOONGEN ./benchmarks/throughput.lua $TXPORT $RXPORT \
                                         -d $TEST_THROUGHPUT_DURATION \
                                         -n $TEST_THROUGHPUT_NUM_ITERATIONS \
                                         -r $TEST_THROUGHPUT_RTHS \
                                         -m $TEST_THROUGHPUT_MLR \
					 -q $TEST_THROUGHPUT_MAXQUEUES \
					 -w $TEST_THROUGHPUT_RESETTIME \
					 -k $TEST_THROUGHPUT_SETTLETIME \
                                         -f $FOLDER_NAME \
                                         -t $USE_RATE_TYPE \
                                         -s $FRAME_SIZES
    if [ $? -ne 0 ]; then
	echo "ERROR: MoonGen script not executed succesfully"
	exit 1
    else
        echo "unset TEST_THROUGHPUT" >> "$CURRENT_DIR/CONFIG.run"
    fi
fi

if [[ -n "$TEST_LATENCY" ]]; then
    echo ""
    echo "-- Starting latency test --"
    echo ""
    $MOONGEN ./benchmarks/latency.lua $TXPORT $RXPORT \
                                         -d $TEST_LATENCY_DURATION \
                                         -r $TEST_LATENCY_RT \
					 -q $TEST_LATENCY_MAXQUEUES \
					 -x $TEST_LATENCY_RATELIMIT \
					 -k $TEST_LATENCY_SETTLETIME \
                                         -f $FOLDER_NAME \
                                         $TEST_LATENCY_RT_OVERRIDE \
                                         -t $USE_RATE_TYPE \
                                         -s $FRAME_SIZES

    if [ $? -ne 0 ]; then
	echo "ERROR: MoonGen script not executed succesfully"
	exit 1
    else
        echo "unset TEST_LATENCY" >> "$CURRENT_DIR/CONFIG.run"
    fi
fi

if [[ -n "$TEST_FRAMELOSS" ]]; then
    echo ""
    echo "-- Starting frameloss test --"
    echo ""
    $MOONGEN ./benchmarks/frameloss.lua $TXPORT $RXPORT \
                                         -d $TEST_FRAMELOSS_DURATION \
                                         -g $TEST_FRAMELOSS_GRANULARITY \
					 -q $TEST_FRAMELOSS_MAXQUEUES \
					 -k $TEST_FRAMELOSS_SETTLETIME \
                                         -f $FOLDER_NAME \
                                         -t $USE_RATE_TYPE \
                                         -s $FRAME_SIZES
    if [ $? -ne 0 ]; then
	echo "ERROR: MoonGen script not executed succesfully"
	exit 1
    else
        echo "unset TEST_FRAMELOSS" >> "$CURRENT_DIR/CONFIG.run"
    fi
fi

if [[ -n "$TEST_BACKTOBACK" ]]; then
    echo ""
    echo "-- Starting backtoback test --"
    echo ""
    $MOONGEN ./benchmarks/backtoback.lua $TXPORT $RXPORT \
                                         -d $TEST_BACKTOBACK_DURATION \
                                         -n $TEST_BACKTOBACK_NUM_ITERATIONS \
                                         -b $TEST_BACKTOBACK_BTHS \
                                         -f $FOLDER_NAME \
                                         -s $FRAME_SIZES
    if [ $? -ne 0 ]; then
	echo "ERROR: MoonGen script not executed succesfully"
	exit 1
    else
        echo "unset TEST_BACKTOBACK" >> "$CURRENT_DIR/CONFIG.run"
    fi
fi


#
# finalize latex file
#
if [[ -z "$TEST_FINISH" ]]; then
    echo ""
    echo "-- Finalizing tex file --"
    echo ""
    $MOONGEN ./benchmarks/finish.lua -f $FOLDER_NAME
    if [ $? -ne 0 ]; then
        echo "ERROR: MoonGen script not executed succesfully"
        exit 1
    else
        echo 'TEST_FINISH="y"' >> "$CURRENT_DIR/CONFIG.run"
    fi
fi

#
# generate report from latex file
#
if [[ -n "$GENERATE_REPORT" ]]; then
    echo ""
    echo "-- Generating report file --"
    echo ""
    # generate PDF report from latex file
    shopt -s nullglob
    for tikzfile in $FOLDER_NAME/*.tikz; do pdflatex --output-directory=$FOLDER_NAME $tikzfile; done

    if [[ $GENERATE_REPORT_TYPE == "pdf" ]]; then
        #run in subshell
        ( 
            cd $FOLDER_NAME
            #pdflatex --output-directory=$FOLDER_NAME $FOLDER_NAME/rfc_2544_testreport.tex
            pdflatex rfc_2544_testreport.tex
	)
        if [[ -f "$FOLDER_NAME/rfc_2544_testreport.pdf" ]]; then
            echo "test report copied to: ./rfc_2544_testreport.pdf"
            mv $FOLDER_NAME/rfc_2544_testreport.pdf ./rfc_2544_testreport_$DATE.pdf
            echo "unset GENERATE_REPORT" >> "$CURRENT_DIR/CONFIG.run"
        else
            echo "ERROR: test report not generated"
            exit 1
        fi
    elif [[ $GENERATE_REPORT_TYPE == "html" ]]; then
        #pdflatex --output-directory=$FOLDER_NAME $FOLDER_NAME/rfc_2544_testreport.tex
        cd $FOLDER_NAME
        htlatex rfc_2544_testreport.tex
	cd ..
        if [[ -f "$FOLDER_NAME/rfc_2544_testreport.html" ]]; then
            echo "test report copied to: ./rfc_2544_testreport_$DATE.html"
            mv $FOLDER_NAME/rfc_2544_testreport.html ./rfc_2544_testreport_$DATE.html
            echo "unset GENERATE_REPORT" >> "$CURRENT_DIR/CONFIG.run"
        else
            echo "ERROR: test report not generated"
            exit 1
        fi
    else
        echo "ERROR: Invalid GENERATE_REPORT_TYPE: $GENERATE_REPORT_TYPE. 'pdf' and 'html' are valid values"
    fi

fi

# finalizing run
echo ""
echo "-- Test run has finished --"
echo ""
mv "$CURRENT_DIR/CONFIG.run" "$CURRENT_DIR/$FOLDER_NAME/CONFIG.log"
echo "config is stored in $CURRENT_DIR/$FOLDER_NAME/CONFIG.log"




