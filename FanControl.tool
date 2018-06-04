#!/bin/bash

#
# Config
#
# ipmitool raw 0x3a 0x01  ${CPU_FAN1} ${Reserved} ${REAR_FAN1} ${REAR_FAN2} ${FRNT_FAN1} ${FRNT_FAN2} ${FRNT_FAN3} ${Reserved}

configFile="${1}"

# Write out a default config file
function fcConfig {
	tee > "${configFile}" <<"EOF"
# FanControl config file

# Set this to 0 to enable
defaultFile="1"

# Fan settings
autoFanDuty="0" # Value that sets fan to auto based on CPU temp.
minFanDuty="30" # Minimum effective value to set duty level to.
maxFanDuty="100" # Maxim value to set duty level to.
difFanDuty="10" # The difference maintained between intake and exhaust fans


# Temperatures in Celsius
targetDriveTemp="30" # The temperature that we try to maintain.
maxDriveTemp="39" # Do not let drives get hotter than this.
ambTempVariance="2" # How many degrees the ambient temperature may effect the target


# PID Controls
Kp="4"	#  Proportional tunable constant
Ki="0"	#  Integral tunable constant
Kd="40"	#  Derivative tunable constant

# Time interval to check disk temps in mins
diskCheckTempInterval="2"


# List of HDs
hdName=(
da0
da1
da2
da3
da4
da5
da6
da7
ada0
ada1
ada2
ada3
)


# Everything below this line is MB specific.
# These examples are for an ASRockRack E3C236D4U.

#
# Currently unused
#
# Fan sensor name prefixes; numbers will be added
# senNamePrefixCPU_FAN="CPU_FAN"
# senNamePrefixFRNT_FAN="FRNT_FAN"
# senNamePrefixREAR_FAN="REAR_FAN"


# Temp sensors
# The names used by ipmi.
# cpuTempSens[0]="CPU1 Temp"		# CPU temp	Currently unused
ambTempSens[0]="MB Temp"		# Ambient temp
ambTempSens[1]="Card Side Temp"	# Ambient temp

# IPMI Fan Commands
#
# The script curently tracks four different types of fan values:
# CPU_FAN is used for fans that directly cool the cpu.
# FRNT_FAN is used for intake fans.
# REAR_FAN is used for exhaust fans.
# NIL_FAN is used for space holder values that are not fans.
#
# Make sure that you set values here corectly for your board.

# The command to set the desired fan duty levels.
function ipmiWrite {
	if ! ipmitool raw 0x3a 0x01 "${CPU_FAN[0]}" "${NIL_FAN[0]}" "${REAR_FAN[0]}" "${NIL_FAN[1]}" "${FRNT_FAN[0]}" "${FRNT_FAN[1]}" "${NIL_FAN[2]}" "${NIL_FAN[3]}"; then
		return ${?}
	fi
}

# A function to read the current fan duty levels.
# It conversts hex values to decimal and seperates them by type.
function ipmiRead {
	local rawFan
	local rawFanAray
	rawFan="$(ipmitool raw 0x3a 0x02 | sed -e 's:^ *::')"
	read -ra rawFanAray <<< "${rawFan}"
	CPU_FAN[0]="$(hexConv "${rawFanAray[0]}")"
	NIL_FAN[0]="$(hexConv "${rawFanAray[1]}")"
	REAR_FAN[0]="$(hexConv "${rawFanAray[2]}")"
	NIL_FAN[1]="$(hexConv "${rawFanAray[3]}")"
	FRNT_FAN[0]="$(hexConv "${rawFanAray[4]}")"
	FRNT_FAN[1]="$(hexConv "${rawFanAray[5]}")"
	NIL_FAN[2]="$(hexConv "${rawFanAray[6]}")"
	NIL_FAN[3]="$(hexConv "${rawFanAray[7]}")"
}

EOF
	exit 0
}

#
# Functions Start Here
#

# ipmi sensor command
function ipmiSens {
	local sensName="${1}"
	ipmitool -c sdr get "${sensName}" | cut -d ',' -f 2
}

# Convert Hex to decimal
function hexConv {
	local hexIn="${1}"
	echo "$((0x${hexIn}))"
}

# Round to nearest whole number
function roundR {
	bc <<< "scale=0;(${1} + 0.5) / 1"
}


# Get set point temp
function targetTemp {
	local ambTemIn
	local ambTemOut="0"
	local ambTemCur

	for ambTemIn in "${ambTempSens[@]}"; do
# 		Get the current ambent temp readings.
		ambTemCur="$(ipmiSens "${ambTemIn}")"
# 		Start adding temps for an average.
		ambTemOut="$(bc <<< "scale=0;${ambTemOut} + ${ambTemCur}")"
	done
# 	Divide by number of sensors for average.
	ambTemOut="$(bc <<< "scale=3;${ambTemOut} / ${#ambTempSens[@]}")"
	ambTemComp="$(roundR "${ambTemOut}")"

# 	Alow the target temp to vary by $ambTempVariance degrees based on
# 	a difference between ambent internal temp and $targetDriveTemp.
	if [ "${ambTemComp}" = "${targetDriveTemp}" ]; then
		echo "${ambTemOut}"
	else
		if [ "${ambTemComp}" -gt "${targetDriveTemp}" ]; then
			if [ "${ambTemComp}" -gt "$(bc <<< "scale=0;${targetDriveTemp} + ${ambTempVariance}")" ]; then
				bc <<< "scale=3;${targetDriveTemp} + ${ambTempVariance}"
				return 0
			fi
		elif [ "${targetDriveTemp}" -gt "${ambTemComp}" ]; then
			if [ "$(bc <<< "scale=0;${targetDriveTemp} - ${ambTempVariance}")" -gt "${ambTemComp}" ]; then
				bc <<< "scale=3;${targetDriveTemp} - ${ambTempVariance}"
				return 0
			fi
		fi
		echo "${ambTemOut}"
	fi
}


# Get average or high HD temperature.
function hdTemp {
	local hdNum
	local hdTempCur
	local hdTempAv="0"
	local hdTempMx="0"

	for hdNum in "${hdName[@]}"; do
# 		Get the temp for the current drive.
# 		194 is the standard SMART id for temp so we look for it at the
# 		begining of the line.
		hdTempCur="$(smartctl -a "/dev/${hdNum}" | grep "^194" | sed -E 's:[[:space:]]+: :g' | cut -d ' ' -f 10)"
# 		Start adding temps for an average.
		hdTempAv="$(( hdTempAv + hdTempCur ))"

# 		Keep track of the highest current temp
		if [ "${hdTempMx}" -gt "${hdTempCur}" ]; then
			hdTempMx="${hdTempMx}"
		else
			hdTempMx="${hdTempCur}"
		fi
	done
# 	Divide by number of drives for average.
	hdTempAv="$(bc <<< "scale=3;${hdTempAv} / ${#hdName[@]}")"

# 	If the hottest drive matches/exceeds the max temp use that instead
# 	of the average.
	if [ "${hdTempMx}" -ge "${maxDriveTemp}" ]; then
		echo "${hdTempMx}"
	else
		echo "${hdTempAv}"
	fi
}


# Set fan duty levels
function setFanDuty {
	local cpuFan
	local intakeFan
	local outputFan
	local cpuFanSet
	local intakeFanSet
	local outputFanSet
	cpuFanSet="$(roundR "${1}")"
	intakeFanSet="$(roundR "${2}")"
	outputFanSet="$(bc <<< "scale=0;${intakeFanSet} - ${difFanDuty}")"

	local count="0"
	for cpuFan in "${CPU_FAN[@]}"; do
		: "${cpuFan}"
		CPU_FAN[${count}]="${cpuFanSet}"
		((count++))
	done

	count="0"
	for intakeFan in "${FRNT_FAN[@]}"; do
		: "${intakeFan}"
		FRNT_FAN[${count}]="${intakeFanSet}"
		((count++))
	done

	count="0"
	for outputFan in "${REAR_FAN[@]}"; do
		: "${outputFan}"
		REAR_FAN[${count}]="${outputFanSet}"
		((count++))
	done
}


# The proportional calculation
function proportionalK {
	local errorK="${1}"
	local contolOuput

	contolOuput="$(bc <<< "scale=3;${errorK} * ${Kp}")"
	echo "${contolOuput}"
}

# The integral calculation
function integralK {
	local errorK="${1}"
	local prevIntegralVal="${2}"
	local contolOuput

	contolOuput="$(bc <<< "scale=3;(${Ki} * (${errorK} * ${diskCheckTempInterval} + ${prevIntegralVal})) / 1")"
	echo "${contolOuput}"
}

# The derivative calculation
function derivativeK {
	local errorK="${1}"
	local prevErrorK="${prevErrorK}"
	local contolOuput

	contolOuput="$(bc <<< "scale=3;(${Kd} * (${errorK} - ${prevErrorK})) / ${diskCheckTempInterval}")"
	echo "${contolOuput}"
}

#
# Main Script Starts Here
#


if [ -z "${configFile}" ]; then
	echo "Please specify a config file location." >&2
	exit 1
elif [ ! -f "${configFile}" ]; then
	fcConfig
fi

# Source external config file
# shellcheck source=/dev/null
. "${configFile}"

# Check if needed software is installed.
PATH="${PATH}:/usr/local/sbin:/usr/local/bin"
commands=(
grep
sed
cut
sleep
bc
smartctl
ipmitool
)
for command in "${commands[@]}"; do
	if ! type "${command}" &> /dev/null; then
		echo "${command} is missing, please install" >&2
		exit 100
	fi
done


# Do not run if the config file has not been edited.
if [ ! "${defaultFile}" = "0" ]; then
	echo "Please edit the config file for your setup" >&2
	exit 1
fi

# Set fans to auto on exit
# trap 'ipmitool raw 0x3a 0x01 ${autoFanDuty} ${autoFanDuty} ${autoFanDuty} ${autoFanDuty} ${autoFanDuty} ${autoFanDuty} ${autoFanDuty} ${autoFanDuty}' 0 1 2 3 6


#
# Setup for main loop.
#

# Get current duty levels.
ipmiRead

# Initialize previous run vars.
: "${prevErrorK:="0"}"
: "${prevProportionalVal:="0"}"
: "${prevIntegralVal:="0"}"
: "${prevDerivativeVal:="0"}"
: "${prevConrtolOutput:="0"}"


#
# Main Loop.
#


while true; do
	setPoint="$(targetTemp)"
	processVar="$(hdTemp)"

# 	Get the error or set to 0 (we only cool, we do not heat).
	if [ "$(roundR "${processVar}")" -le "$(roundR "${setPoint}")" ]; then
		errorK="0"
	else
		errorK="$(bc <<< "scale=3;${processVar} - ${setPoint}")"
	fi


# 	Compute an unqualified control output (P+I+D).
	proportionalVal="$(proportionalK "${errorK}")"
	integralVal="$(integralK "${errorK}" "${prevIntegralVal}")"
	derivativeVal="$(derivativeK "${errorK}" "${prevErrorK}")"

	unQualConrtolOutput="$(bc <<< "scale=3;${prevConrtolOutput} + ${proportionalVal} + ${integralVal} + ${derivativeVal}")"


# 	Qualify the output to ensure we are inside the constraints.
	if [ "$(roundR "${unQualConrtolOutput}")" -lt "${minFanDuty}" ]; then
		qualConrtolOutput="${minFanDuty}"
	elif [ "$(roundR "${unQualConrtolOutput}")" -gt "${maxFanDuty}" ]; then
		qualConrtolOutput="${maxFanDuty}"
	else
		qualConrtolOutput="$(roundR "${unQualConrtolOutput}")"
	fi


# 	Set the duty levels for each fan type.
	setFanDuty "${autoFanDuty}" "${qualConrtolOutput}"


# 	Write out the new duty levels to ipmi.
# 	shellcheck disable=SC2086
	if ! ipmiWrite; then
		exit 1
	fi

# 	Set vars for next run
	prevErrorK="${errorK}"
	prevProportionalVal="${proportionalVal}"
	prevIntegralVal="${integralVal}"
	prevDerivativeVal="${derivativeVal}"
	prevConrtolOutput="${qualConrtolOutput}"


	sleep "$(( 60 * diskCheckTempInterval ))"
done
