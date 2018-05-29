#!/bin/bash

# Config
# ipmitool raw 0x3a 0x01  ${CPU_FAN1} ${Reserved} ${REAR_FAN1} ${REAR_FAN2} ${FRNT_FAN1} ${FRNT_FAN2} ${FRNT_FAN3} ${Reserved}

# Write out a default config file
fcConfig() {
	tee > "${configFile}" << EOF
# FanControl config file

# Set this to 0 to enable
defaultFile="1"

# Fan settings
autoFanDuty="0" # Value that sets fan to auto based on CPU temp.
minFanDuty="30" # Minimum effective value to set duty level to.
maxFanDuty="100" # Maxim value to set duty level to.
difFanDuty="10" # The difference maintained between intake and exaust fans


# Temperatures in Celsius
targetDriveTemp="30" # The temperature that we try to maintain.
ambTempVariance="5" # How many degrees the ambient temperature may effect the target

# Temp sensors
cpuTempSens[0]="CPU1 Temp"		# CPU temp
ambTempSens[0]="MB Temp"		# Ambient temp
ambTempSens[1]="Card Side Temp"	# Ambient temp


# PID Controls
Kp=4	#  Proportional tunable constant
Ki=0	#  Integral tunable constant
Kd=40	#  Derivative tunable constant


# Time interval to check disk temps in mins
diskCheckTempInterval="5"

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


#
# IPMI Fan Commands
#
# The script curently tracks four different types of fan values:
# CPU_FAN is used for fans that directly cool the cpu.
# FRNT_FAN is used for intake fans.
# REAR_FAN is used for exaust fans.
# NIL_FAN is used for space holder values that are not fans.

# Fan sensor name prefixes; numbers will be added
senNamePrefixCPU_FAN="CPU_FAN"
senNamePrefixFRNT_FAN="FRNT_FAN"
senNamePrefixREAR_FAN="REAR_FAN"


# The command to set the desired fan duty levels.
ipmiWrite="raw 0x3a 0x01 ${CPU_FAN[0]} ${NIL_FAN[0]} ${REAR_FAN[0]} ${NIL_FAN[1]} ${FRNT_FAN[0]} ${FRNT_FAN[1]} ${NIL_FAN[2]} ${NIL_FAN[3]}"

# A function to read the current fan duty levels.
# It conversts hex values to decimal and seperates them by type.
ipmiRead() {
	read -ra rawFanAray <<< "$(ipmitool raw 0x3a 0x02 | sed -e 's:^ *::')"
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


# ipmi sensor command
ipmiSens() {
	local sensName="${1}"
	ipmitool -c sdr get "${sensName}" | cut -d ',' -f 2
}


# Convert Hex to decimal
hexConv() {
	local hexIn="${1}"
	echo "$((0x${hexIn}))"
}


#
# Main Script Starts Here
#

#check if needed software is installed
commands=(
grep
awk
sed
tr
cut
sleep
)
for command in "${commands[@]}"; do
	if ! type "${command}" &> /dev/null; then
		echo "${command} is missing, please install" >&2
		exit 100
	fi
done



if [ ! -f "${configFile}" ]; then
	fcConfig
fi

# Source external config file
. "${configFile}"


if [ ! "${defaultFile}" = "0" ]; then
	echo "Please edit the config file for your setup" >&2
	exit 1
fi
