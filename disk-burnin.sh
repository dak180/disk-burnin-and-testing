#!/bin/bash
########################################################################
#
# disk-burnin.sh
#
# A script to simplify the process of burning-in disks. Intended for use
# only on disks which do not contain valuable data, such as new disks or
# disks which are being tested or re-purposed.
#
# Be aware that:
#
# 	1> This script runs the badblocks program in destructive mode,
# 	which erases any data on the disk.
#
# 	!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# 	!!!        WILL DESTROY THE DISK CONTENTS! BE CAREFUL!        !!!
# 	!!! DO NOT RUN THIS SCRIPT ON DISKS CONTAINING DATA YOU VALUE !!!
# 	!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
# 	2> Run times for large disks can take several days to complete, so
# 	it is a good idea to use tmux sessions to prevent mishaps.
#
# 	3> Must be run as 'root'.
#
# 	4> Tests of large drives can take days to complete: use tmux!
#
# Performs these steps:
#
# 	1> Run SMART short test
# 	2> Run SMART extended test
# 	3> Run badblocks
# 	4> Run SMART short test
# 	5> Run SMART extended test
#
# The script sleeps after starting each SMART test, using a duration
# based on the polling interval reported by the disk, after which the
# script will poll the disk to verify the self-test has completed.
#
# Full SMART information is pulled after each SMART test. All output
# except for the sleep command is echoed to both the screen and log file.
#
# You should monitor the burn-in progress and watch for errors, particularly
# any errors reported by badblocks, or these SMART errors:
#
# 	5 Reallocated_Sector_Ct
# 196 Reallocated_Event_Count
# 197 Current_Pending_Sector
# 198 Offline_Uncorrectable
#
# These indicate possible problems with the drive. You therefore may
# wish to abort the remaining tests and proceed with an RMA exchange
# for new drives or discard old ones. Also please note that this list
# is not exhaustive.
#
# The script extracts the drive model and serial number and forms a
# log filename of the form 'burnin-[model]_[serial number].log'.
#
# badblocks is invoked with a block size of 4096, the -wsv options,
# and the -o option to instruct it to write the list of bad blocks
# found (if any) to a file named 'burnin-[model]_[serial number].bb'.
#
# The only required command-line argument is the device specifier,
# e.g.:
#
# 	./disk-burnin.sh sda
#
# ...will run the burn-in test on device /dev/sda
#
# You can run the script in 'dry run mode' (see below) to check the
# sleep duration calculations and to insure that the sequence of
# commands suits your needs. In 'dry runs' the script does not
# actually perform any SMART tests or invoke the sleep or badblocks
# programs. The script is distributed with 'dry runs' enabled, so you
# will need to edit the Dry_Run variable below, setting it to 0, in
# order to actually perform tests on drives.
#
# Before using the script on FreeBSD systems (including FreeNAS) you
# must first execute this sysctl command to alter the kernel's
# geometry debug flags. This allows badblocks to write to the entire
# disk:
#
# 	sysctl kern.geom.debugflags=0x10
#
# Tested under:
# 	FreeNAS 9.10.2 (FreeBSD 10.3-STABLE)
# 	Ubuntu Server 16.04.2 LTS
#
# Tested on:
# 	Intel DC S3700 SSD
# 	Intel Model 320 Series SSD
# 	HGST Deskstar NAS (HDN724040ALE640)
# 	Hitachi/HGST Ultrastar 7K4000 (HUS724020ALE640)
# 	Western Digital Re (WD4000FYYZ)
# 	Western Digital Black (WD6001FZWX)
#
# Requires the smartmontools, available at https://www.smartmontools.org
#
# Uses: grep, awk, sed, tr, sleep, badblocks
#
# Written by Keith Nash, March 2017
#
# KN, 8 Apr 2017:
# 	Added minimum test durations because some devices don't return
# 	accurate values.
# 	Added code to clean up the log file, removing copyright notices,
# 	etc.
# 	No longer echo 'smartctl -t' output to log file as it imparts no
# 	useful information.
# 	Emit test results after tests instead of full
# 	'smartctl -a' output.
# 	Emit full 'smartctl -x' output at the end of all testing.
# 	Minor changes to log output and formatting.
#
# KN, 12 May 2017:
# 	Added code to poll the disk and check for completed self-tests.
#
# 	As noted above, some disks don't report accurate values for the
# 	short and extended self-test intervals, sometimes by a significant
# 	amount. The original approach using 'fudge' factors wasn't
# 	reliable and the script would finish even though the SMART
# 	self-tests had not completed. The new polling code helps insure
# 	that this doesn't happen.
#
# 	Fixed code to work around annoying differences between sed's
# 	behavior on Linux and FreeBSD.
#
# KN, 8 Jun 2017
#
# Modified by Yifan Liao
# 	Modified parsing of short and extended test durations to
# 	accommodate the values returned by larger drives; we needed to
# 	strip out the '(' and ')' characters surrounding the integer value
# 	in order to fetch it reliably.
#
########################################################################

function dbUsage() {
	tee >&2 << EOF
Usage: ${0} [-h] [-t] [-l directory] [-b directory] {-d drive-device-specifier | -m drive-device-specifier-list}
Run SMART tests and burn-in tests on a drive.
...

Options:
-h
	Display this help and exit.

-t
	Needed to actually run the tests, By default ${0} will just do a dry run.

-d
	Drive Device Specifier.

-m
	Space separated list of Drive Device Specifiers to run via tmux.

-l
	Log files directory.

-b
	Bad blocks files directory.
...
EOF
}

Log_Dir="."
BB_Dir="."
Dry_Run=1

while getopts ":d:m:l:b:th" OPTION; do
	case "${OPTION}" in
		d)
			driveID="${OPTARG}"
		;;
		m)
			driveIDs="${OPTARG}"
		;;
		l)
			Log_Dir="${OPTARG}"
		;;
		b)
			BB_Dir="${OPTARG}"
		;;
		t)
			Dry_Run=0
		;;
		h | ?)
			dbUsage
			exit 0
		;;
	esac
done

#check if needed software is installed
commands=(
jq
grep
date
tee
smartctl
awk
sed
tr
sleep
badblocks
)
if [ ! -z "${driveIDs}" ]; then
commands+=(
tmux
)
fi
for command in "${commands[@]}"; do
	if ! type "${command}" &> /dev/null; then
		echo "${command} is missing, please install"
		exit 100
	fi
done


if [ ! -z "${driveIDs}" ]; then
	IFS=' ' read -a devIDs <<< "${driveIDs}"
	for devID in "${devIDs[@]}"; do
		if [ ! -e "/dev/${devID}" ]; then
			echo "error: Drive Device Specifier ${devID} does not exist." 1>&2
			exit 4
		fi
		if [ "${Dry_Run}" ="0" ]; then
			tmux new -d -n "${devID}" "$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )/disk-burnin.sh" -td "${devID}"
		else
			echo "tmux new -d -n \"${devID}\" \"$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )/disk-burnin.sh\" -d \"${devID}\""
		fi
	done

	exit 0
fi


if [ -z "${driveID}" ]; then
	echo "error: No Drive Device Specifier." 1>&2
	dbUsage
	exit 4
elif [ ! -e "/dev/${driveID}" ]; then
	echo "error: Drive Device Specifier does not exist." 1>&2
	exit 4
fi

######################################################################
#
# Prologue
#
######################################################################


SMART_capabilities="$(smartctl -jc "/dev/${driveID}")"

SMART_info="$(smartctl -ji "/dev/${driveID}")"

# Obtain the disk model:

Disk_Model="$(echo "${SMART_info}" | jq -Mre '.model_name | values')"

if [ -z "${Disk_Model}" ]; then
  Disk_Model="$(echo "${SMART_info}" | jq -Mre '.model_family | values')"
fi

# Obtain the disk serial number:

Serial_Number="$(echo "${SMART_info}"  | jq -Mre '.serial_number | values')"

# Test to see if disk is a SSD:

if [ "$(echo "${SMART_info}" | jq -Mre '.rotation_rate | values')" = "0" ] || [ "$(echo "${SMART_info}" | jq -Mre '.device.type | values')" = "nvme" ]; then
	driveType="ssd"
fi

# Test to see if it is necessary to specify connection type:

SMART_deviceType="$(smartctl -d test "/dev/${driveID}")"

if echo "${SMART_deviceType}" | grep -q "Device open changed type"; then
	if echo "${SMART_deviceType}" | grep -q "[SAT]:"; then
		driveConnectionType="sat,auto"
	fi
else
	driveConnectionType="auto"
fi


# Form the log and bad blocks data filenames:

Log_Name="${Log_Dir}/burnin-${Disk_Model}_${Serial_Number}-$(date -u +%Y%m%d-%H%M+0)"

Log_File="${Log_Name}.log"

BB_File="${Log_Name}.bb"

# Query the short and extended test duration, in minutes. Use the values to
# calculate how long we should sleep after starting the SMART tests:

Short_Test_Minutes="$(echo "${SMART_capabilities}" | jq -Mre '.ata_smart_data.self_test.polling_minutes.short | values')"
#printf "Short_Test_Minutes=[%s]\n" ${Short_Test_Minutes}

Conveyance_Test_Minutes="$(echo "${SMART_capabilities}" | jq -Mre '.ata_smart_data.self_test.polling_minutes.conveyance | values')"
#printf "Conveyance_Test_Minutes=[%s]\n" ${Conveyance_Test_Minutes}

Extended_Test_Minutes="$(echo "${SMART_capabilities}" | jq -Mre '.ata_smart_data.self_test.polling_minutes.extended | values')"
#printf "Extended_Test_Minutes=[%s]\n" ${Extended_Test_Minutes}

Short_Test_Sleep="$((Short_Test_Minutes*60))"
Conveyance_Test_Sleep="$((Conveyance_Test_Minutes*60))"
Extended_Test_Sleep="$((Extended_Test_Minutes*60))"
Offline_Test_Sleep="$(echo "${SMART_capabilities}" | jq -Mre '.ata_smart_data.offline_data_collection.completion_seconds | values')"

# Selftest polling timeout interval, in hours
Poll_Timeout_Divisor="5"

# Calculate the selftest polling timeout interval in seconds
Poll_Timeout="$((Extended_Test_Sleep / Poll_Timeout_Divisor))"

# Polling sleep interval, in seconds:
Poll_Interval="15"

######################################################################
#
# Local functions
#
######################################################################

function echo_str() {
	echo "$1" | tee -a "${Log_File}"
}

function push_header() {
	echo_str "+-----------------------------------------------------------------------------"
}

function test_error() {
	local errNum="$1"

	push_header
	if [ "${errNum}" = "2" ]; then
		echo_str "SMART test failed for ${driveID} (${Serial_Number}); exiting."
	elif [ "${errNum}" = "1" ]; then
		echo_str "SMART test timed out for ${driveID} (${Serial_Number}); exiting."
	fi
	push_header

	smartctl -l selftest "/dev/${driveID}" | tee -a "${Log_File}"

	mv "${Log_File}" "${Log_Name}.error.log"

	exit "${errNum}"
}

function poll_selftest_complete() {
	local smrtOut="$(smartctl -ja "/dev/${driveID}")"
	local smrtPrcnt="$(echo "${smrtOut}" | jq -Mre '.ata_smart_data.self_test.status.remaining_percent | values')"
	local pollDuration="0"
	local st_rv="1"

	# Check SMART results for to see if the self-test routine completed.
	# Return 0 if the test has completed,
	# 1 if we exceed our polling timeout interval, and
	# 2 if there is an error.

	while [ ! -z "${smrtPrcnt}" ]; do
		# If the test has not finished yet wait until it does
		if [ "${pollDuration}" -ge "${Poll_Timeout}" ]; then
			echo_str "Timeout polling for SMART self-test status"
			return "${st_rv}"
		else
			sleep "${Poll_Interval}"
			pollDuration="$((pollDuration + Poll_Interval))"
		fi

		# Set the vars for the next run
		smrtOut="$(smartctl -ja "/dev/${driveID}")"
		smrtPrcnt="$(echo "${smrtOut}" | jq -Mre '.ata_smart_data.self_test.status.remaining_percent | values')"
	done



	if [ "$(echo "${smrtOut}" | jq -Mre '.ata_smart_data.self_test.status.passed | values')" = "true" ]; then
		# Check for success
		echo_str "SMART self-test complete"
		st_rv="0"
	else
		echo_str "SMART self-test failed"
		st_rv="2"
	fi


	return "${st_rv}"
}

function run_short_test() {
	push_header
	echo_str "+ Run SMART short test on drive /dev/${driveID}: $(date)"
	push_header

	if [ "${Dry_Run}" -eq "0" ]; then
		smartctl -d "${driveConnectionType}" -t short "/dev/${driveID}"

		echo_str "Short test started, sleeping ${Short_Test_Sleep} seconds until it finishes"

		sleep "${Short_Test_Sleep}"

		if ! poll_selftest_complete; then
			test_error "${?}"
		fi

		smartctl -l selftest "/dev/${driveID}" | tee -a "${Log_File}"
	else
		echo_str "Dry run: would start the SMART short test and sleep ${Short_Test_Sleep} seconds until the test finishes"
	fi

	echo_str "Finished SMART short test on drive /dev/${driveID}: $(date)"
}

function run_conveyance_test() {
	if [ -z "${Conveyance_Test_Minutes}" ]; then
		push_header
		echo_str "+ SMART conveyance test not supported by /dev/${driveID}; skipping."
		push_header
	else
		push_header
		echo_str "+ Run SMART conveyance test on drive /dev/${driveID}: $(date)."
		push_header

		if [ "${Dry_Run}" -eq "0" ]; then
			smartctl -d "${driveConnectionType}" -t conveyance "/dev/${driveID}"

			echo_str "Conveyance test started, sleeping ${Conveyance_Test_Sleep} seconds until it finishes."

			sleep "${Conveyance_Test_Sleep}"

			if ! poll_selftest_complete; then
				test_error "${?}"
			fi

			smartctl -l selftest "/dev/${driveID}" | tee -a "${Log_File}"
		else
			echo_str "Dry run: would start the SMART conveyance test and sleep ${Conveyance_Test_Sleep} seconds until the test finishes."
		fi

		echo_str "Finished SMART conveyance test on drive /dev/${driveID}: $(date)."
	fi
}

function run_offline_test() {
	if [ -z "${Offline_Test_Sleep}" ]; then
		push_header
		echo_str "+ SMART offline testing not supported by /dev/${driveID}; skipping."
		push_header
	else
		push_header
		echo_str "+ Run SMART offline test on drive /dev/${driveID}: $(date)."
		push_header

		if [ "${Dry_Run}" -eq "0" ]; then
			smartctl -d "${driveConnectionType}" -t offline "/dev/${driveID}"

			echo_str "Offline test started, sleeping ${Offline_Test_Sleep} seconds until it finishes."

			sleep "${Offline_Test_Sleep}"

			poll_selftest_complete

			smartctl --offlineauto="on" "/dev/${driveID}" | tee -a "${Log_File}"

			smartctl -l selftest "/dev/${driveID}" | tee -a "${Log_File}"
		else
			echo_str "Dry run: would start the SMART offline test and sleep ${Offline_Test_Sleep} seconds until the test finishes."
		fi

		echo_str "Finished SMART offline test and activated automated testing (if supported) on drive /dev/${driveID}: $(date)."
	fi
}

function run_extended_test() {
	push_header
	echo_str "+ Run SMART extended test on drive /dev/${driveID}: $(date)"
	push_header

	if [ "${Dry_Run}" -eq "0" ]; then
		smartctl -d "${driveConnectionType}" -t long "/dev/${driveID}"

		echo_str "Extended test started, sleeping ${Extended_Test_Sleep} seconds until it finishes"

		sleep "${Extended_Test_Sleep}"

		if ! poll_selftest_complete; then
			test_error "${?}"
		fi

		smartctl -l selftest "/dev/${driveID}" | tee -a "${Log_File}"
	else
		echo_str "Dry run: would start the SMART extended test and sleep ${Extended_Test_Sleep} seconds until the test finishes"
	fi

	echo_str "Finished SMART extended test on drive /dev/${driveID}: $(date)"
}

function run_badblocks_test() {
	push_header
	echo_str "+ Run badblocks test on drive /dev/${driveID}: $(date)"
	push_header

	if [ "${Dry_Run}" -eq "0" ]; then
		#
		# This command will erase all data on the disk:
		#
		badblocks -b "4096" -c "32" -wsv -o "${BB_File}" "/dev/${driveID}"
	else
		echo_str "Dry run: would run badblocks -b 4096 -c 32 -wsv -o ${BB_File} /dev/${driveID}"
	fi

	echo_str "Finished badblocks test on drive /dev/${driveID}: $(date)"
}

######################################################################
#
# Action begins here
#
######################################################################

if [ -e "${Log_File}" ]; then
  rm "${Log_File}"
fi

tee -a "${Log_File}" << EOF
+-----------------------------------------------------------------------------
+ Started burn-in of /dev/${driveID} : $(date)
+-----------------------------------------------------------------------------
Host: $(hostname)
Drive Model: ${Disk_Model}
Serial Number: ${Serial_Number}
Short test duration: ${Short_Test_Minutes} minutes
Short test sleep duration: ${Short_Test_Sleep} seconds
Conveyance test duration: ${Conveyance_Test_Minutes} minutes
Conveyance test sleep duration: ${Conveyance_Test_Sleep} seconds
Extended test duration: ${Extended_Test_Minutes} minutes
Extended test sleep duration: ${Extended_Test_Sleep} seconds
Log file: ${Log_File}
Bad blocks file: ${BB_File}
EOF

# Run the test sequence:
run_offline_test
run_short_test
run_conveyance_test
run_extended_test
if [ ! "${driveType}" = "ssd" ]; then
	run_badblocks_test
	run_short_test
	run_extended_test
	run_offline_test
fi

# Emit full device information to log:
tee -a "${Log_File}" << EOF
+-----------------------------------------------------------------------------
+ SMART information for drive /dev/${driveID}: $(date)
+-----------------------------------------------------------------------------
$(smartctl -x "/dev/${driveID}")
+-----------------------------------------------------------------------------
+ Finished burn-in of /dev/${driveID} : $(date)
+-----------------------------------------------------------------------------
EOF

# Clean up the log file:

osflavor=$(uname)

if [ "${osflavor}" = "Linux" ]; then
	sed -i -e '/Copyright/d' "${Log_File}"
	sed -i -e '/=== START OF READ/d' "${Log_File}"
	sed -i -e '/=== START OF SMART DATA SECTION ===/d' "${Log_File}"
	sed -i -e '/SMART Attributes Data/d' "${Log_File}"
	sed -i -e '/Vendor Specific SMART/d' "${Log_File}"
	sed -i -e '/SMART Error Log Version/d' "${Log_File}"
fi

if [ "${osflavor}" = "FreeBSD" ]; then
	sed -i '' -e '/Copyright/d' "${Log_File}"
	sed -i '' -e '/=== START OF READ/d' "${Log_File}"
	sed -i '' -e '/=== START OF SMART DATA SECTION ===/d' "${Log_File}"
	sed -i '' -e '/SMART Attributes Data/d' "${Log_File}"
	sed -i '' -e '/Vendor Specific SMART/d' "${Log_File}"
	sed -i '' -e '/SMART Error Log Version/d' "${Log_File}"
fi
