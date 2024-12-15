#!/bin/bash
# shellcheck disable=SC2236,SC2155
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
# 	2> Run times for large disks can take several days (or more) to complete, so
# 	it is a good idea to use tmux sessions to prevent mishaps.
#
# 	3> Must be run as 'root'.
#
# 	4> Read the README.md file before using.
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
# KN, 5 Feb 2024
#
#   Mostly rewritten by dak180
#
#
########################################################################

## Prolog Functions

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

-L
	Print list of Drive Device Specifiers and exit
...
EOF
}

function get_drive_list() {
	local drives
	local localDriveList

	localDriveList="$(smartctl --scan | cut -d ' ' -f "1" | sed -e 's:/dev/::')"

	if [ "${systemType}" = "BSD" ]; then
		# This sort breaks on linux when going to four leter drive ids: "sdab"; it works fine for bsd's numbered drive ids though.
		readarray -t "drives" <<< "$(for drive in ${localDriveList}; do
			if [ "${smartctl_vers_74_plus}" = "true" ] && [ "$(smartctl -ji "/dev/${drive}" | jq -Mre '.smart_support.enabled | values')" = "true" ]; then
				printf "%s\n" "${drive}"
			elif smartctl -i "/dev/${drive}" | sed -e 's:[[:blank:]]\{1,\}: :g' | grep -q "SMART support is: Enabled"; then
				printf "%s\n" "${drive}"
			elif grep -q "nvme" <<< "${drive}"; then
				printf "%s\n" "${drive}"
			fi
		done | sort -V | sed '/^nvme/!H;//p;$!d;g;s:\n::')"
	else
		readarray -t "drives" <<< "$(for drive in ${localDriveList}; do
			if [ "${smartctl_vers_74_plus}" = "true" ] && [ "$(smartctl -ji "/dev/${drive}" | jq -Mre '.smart_support.enabled | values')" = "true" ]; then
				printf "%s\n" "${drive}"
			elif smartctl -i "/dev/${drive}" | sed -e 's:[[:blank:]]\{1,\}: :g' | grep -q "SMART support is: Enabled"; then
				printf "%s\n" "${#drive} ${drive}"
			elif grep -q "nvme" <<< "${drive}"; then
				printf "%s\n" "${#drive} ${drive}"
			fi
		done | sort -Vbk 1 -k 2 | cut -d ' ' -f 2 | sed '/^nvme/!H;//p;$!d;g;s:\n::')"
	fi

	echo "${drives[@]}"
}


# Check if we are running on BSD
if [[ "$(uname -mrs)" =~ .*"BSD".* ]]; then
	systemType="BSD"
fi

# Get the version numbers for smartctl
major_smartctl_vers="$(smartctl -jV | jq -Mre '.smartctl.version[] | values' | sed '1p;d')"
minor_smartctl_vers="$(smartctl -jV | jq -Mre '.smartctl.version[] | values' | sed '2p;d')"
if [[ "${major_smartctl_vers}" -gt "7" ]]; then
	smartctl_vers_74_plus="true"
elif [[ "${major_smartctl_vers}" -eq "7" ]] && [[ "${minor_smartctl_vers}" -ge "4" ]]; then
	smartctl_vers_74_plus="true"
elif [ -z "${major_smartctl_vers}" ]; then
	echo "smartctl version 7 or greater is required" >&2
	smartctl -V
	exit 1
fi

Log_Dir="."
Dry_Run=1

while getopts ":d:m:l:Lth" OPTION; do
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
		L)
			get_drive_list
			exit 0
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
cut
date
tee
smartctl
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
if [ "${systemType}" = "BSD" ]; then
commands+=(
sysctl
# nvmecontrol
)
fi
for command in "${commands[@]}"; do
	if ! type "${command}" &> /dev/null; then
		echo "${command} is missing, please install"
		exit 100
	fi
done


# Must be run as root for effect
if [ ! "$(whoami)" = "root" ] && [ ! "${Dry_Run}" = "0" ]; then
	echo "Must be run as root." >&2
	exit 1
fi


if [ ! -z "${driveIDs}" ]; then
	IFS=' ' read -ra devIDs <<< "${driveIDs}"
	for devID in "${devIDs[@]}"; do
		if [ ! -e "/dev/${devID}" ]; then
			echo "error: Drive Device Specifier ${devID} does not exist." 1>&2
			exit 4
		fi
		if [ "${Dry_Run}" = "0" ]; then
			tmux new -d -n "${devID}" "$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )/$(basename "${0}")" -td "${devID}"
		else
			echo 'tmux new -d -n "${devID}" "$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )/$(basename "${0}")" -td "${devID}"'
		fi
	done
	tmux ls

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


SM_Vers="$(smartctl --version | grep 'smartctl [6-9].[0-9]' | cut -f "2" -d ' ')"

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

Log_Name="${Log_Dir}/burnin-${Disk_Model}-${Serial_Number}-$(date -u +%Y%m%d-%H%M+0)"

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
Poll_Timeout_Divisor="20"

# Calculate the selftest polling timeout interval in seconds
Poll_Timeout="$((Extended_Test_Sleep / Poll_Timeout_Divisor))"

# Make sure the poll timeout is at least 15 mins
if [ "${Poll_Timeout}" -lt "900" ]; then
  Poll_Timeout="$((Poll_Timeout + 900 ))"
fi

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
	elif [ "${errNum}" = "9" ]; then
		echo_str "Badblocks test failed for ${driveID} (${Serial_Number}); exiting."
	fi
	push_header

	smartctl -l selftest "/dev/${driveID}" | tee -a "${Log_File}"

	mv "${Log_File}" "${Log_Name}.error.log"

	exit "${errNum}"
}

function tler_activation() {
	local tlerStatus

	tlerStatus="$(smartctl -jl scterc "/dev/${driveID}" | jq -Mre '.ata_sct_erc | values')"


	if [ ! -z "${tlerStatus}" ]; then
		if [ ! "$(echo "${tlerStatus}" | jq -Mre '.read.enabled | values')" = "true" ] || [ ! "$(echo "${tlerStatus}" | jq -Mre '.write.enabled | values')" = "true" ]; then
			smartctl -l scterc,70,70 "/dev/${driveID}"
		fi
	fi

	smartctl -l scterc "/dev/${driveID}" | tail -n +3 | tee -a "${Log_File}"
}

function poll_selftest_complete() {
	local smrtOut
	local smrtPrcnt
	local pollDuration="0"
	local st_rv="1"

	smrtOut="$(smartctl -ja "/dev/${driveID}")"
	smrtPrcnt="$(jq -Mre '.ata_smart_data.self_test.status.remaining_percent | values' <<< "${smrtOut}")"

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
		smrtPrcnt="$(jq -Mre '.ata_smart_data.self_test.status.remaining_percent | values' <<< "${smrtOut}")"
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
	local pBlockSize="$(echo "${SMART_info}" | jq -Mre '.physical_block_size | values')"
	local lBlockSize="$(echo "${SMART_info}" | jq -Mre '.logical_block_size | values')"
	local blockNumber="$(echo "${SMART_info}" | jq -Mre '.user_capacity.blocks | values')"
	local bitMax="4294967295"
	local bRatio="$((pBlockSize / lBlockSize))"
	local tBlockNumber="$((blockNumber / bRatio))"
	local tBlockSize


	# Badblocks can only address 32bits max
	tBlockSize="${pBlockSize}"
	while [ "${bitMax}" -lt "${tBlockNumber}" ]; do
		tBlockSize="$((tBlockSize * 2))"
		tBlockNumber="$((tBlockNumber / 2))"
	done


	push_header
	echo_str "+ Run badblocks test on drive /dev/${driveID}: $(date)"
	push_header

	if [ "${Dry_Run}" -eq "0" ]; then
		#
		# This command will erase all data on the disk:
		#
		if ! badblocks -b "${tBlockSize}" -c "32" -e "1" -wsv -o "${BB_File}" "/dev/${driveID}"; then
			test_error "9"
		fi
	else
		echo_str "Dry run: would run badblocks -b ${tBlockSize} -c 32 -e 1 -wsv -o ${BB_File} /dev/${driveID}"
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
tler_activation
# shellcheck disable=SC2072
if [[ "7.3" < "${SM_Vers}" ]] || [ ! "$(echo "${SMART_info}" | jq -Mre '.device.type | values')" = "nvme" ]; then
	# Do not try to test with a version that cannot run NVMe tests
	run_short_test
	run_conveyance_test
	run_extended_test
	run_offline_test
fi
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

osflavor="$(uname)"

if [ "${osflavor}" = "Linux" ]; then
	sed -i -e '/smartctl [6-9].[0-9]/d' "${Log_File}"
	sed -i -e '/Copyright/d' "${Log_File}"
	sed -i -e '/=== START OF READ/d' "${Log_File}"
	sed -i -e '/=== START OF SMART DATA SECTION ===/d' "${Log_File}"
	sed -i -e '/SMART Attributes Data/d' "${Log_File}"
	sed -i -e '/Vendor Specific SMART/d' "${Log_File}"
	sed -i -e '/SMART Error Log Version/d' "${Log_File}"
fi

if [ "${osflavor}" = "FreeBSD" ]; then
	sed -i '' -e '/smartctl [6-9].[0-9]/d' "${Log_File}"
	sed -i '' -e '/Copyright/d' "${Log_File}"
	sed -i '' -e '/=== START OF READ/d' "${Log_File}"
	sed -i '' -e '/=== START OF SMART DATA SECTION ===/d' "${Log_File}"
	sed -i '' -e '/SMART Attributes Data/d' "${Log_File}"
	sed -i '' -e '/Vendor Specific SMART/d' "${Log_File}"
	sed -i '' -e '/SMART Error Log Version/d' "${Log_File}"
fi
