#!/usr/bin/env bash

eta=60 # Estimated time of arrival in seconds. Broken task after ETA is marked as finished. Debug value is 60


if [ -f "./sonmcli" ]; then
	sonmcli="./sonmcli"
else
	sonmcli="sonmcli"
fi

required_vars=(tag ramsize storagesize cpucores sysbenchsingle sysbenchmulti netdownload netupload price numberofnodes identity incoming overlay)
missing_vars=()
nodesArr[0]=true

check_installed() {
	EXIT=0
	for cmd in "jq" "xxd" $sonmcli; do
		if ! [ -x "$(command -v $cmd)" ]; then
			echo "Error: $cmd is not installed." >&2
			EXIT=1
		fi
	done
	if [ "$EXIT" -eq 1 ]; then
		exit 1
	fi
}

check_installed

load_cfg() {
	if [ -f "config.sh" ]; then
		. config.sh
		for i in "${required_vars[@]}"; do
			test -n "${!i:+y}" || missing_vars+=("$i")
		done
		if [ ${#missing_vars[@]} -ne 0 ]; then
			echo "The following variables are not set, but should be:" >&2
			printf ' %q\n' "${missing_vars[@]}" >&2
			exit 1
		fi
	fi
}

datelog() {
	date '+%Y-%m-%d %H:%M:%S'
}

load_generator() {
	if [ -f "bid_gen.sh" ]; then
		. bid_gen.sh
		else
			exit 1
		fi
}

retry() {
	local n=1
	local max=3
	local delay=15
	while true; do
		"$@" && break || {
			if [[ $n -lt $max ]]; then
				((n++))
				sleep $delay
			else
				echo "$(datelog)" "$* command has failed after $n attempts."
				return 1
			fi
		}
	done
}


getDeals() {
	if dealsJson=$(retry "$sonmcli" deal list --out=json); then
		if [ "$(jq '.deals' <<<$dealsJson)" != "null" ]; then

			jq -r '.deals[].id' <<<$dealsJson | tr ' ' '\n' | sort -u | tr '\n' ' '

		fi
	else
		return 1
	fi
}

getOrders() {
	if ordersJson=$(retry "$sonmcli" order list --out=json); then
		if [ "$(jq '.orders' <<<$ordersJson)" != "null" ]; then
			jq -r '.orders[].id' <<<$ordersJson | tr ' ' '\n' | sort -u | tr '\n' ' '
		fi
	else
		return 1
	fi
}


get_time() { #dealid taskid
	time=$($sonmcli task status $1 $2 --out json | jq '.uptime' | sed -e 's/"//g')
	time=$(($time/1000000000))
}
resolve_node_num_task() { #dealid taskid
	node_num=$($sonmcli task status $1 $2 | grep "Tag: data:" | awk '{ FS= ":" } { print $(NF-1) }' | sed -e 's/"//g')
	if [ ! -z $node_num ]; then
	echo "$datelog" "Failed to resolve node number for task."
	fi
	
}

blacklist() { # dealid #file
		echo "$(datelog)" "Failed to start task on deal $1 and blacklisting counterparty worker's address..."
		retry sonmcli deal close $1 --blacklist worker
}

deal_mon() {
	if [ "retry "$sonmcli" deal list --out=json" != null ]; then
		for x in $("$sonmcli" deal list --out json | jq -r '.deals[].id' | sort -u); 
			do
			deal_id=$x
			bid_id=$("$sonmcli" deal status $deal_id --out json | jq -r '.deal.bidID')
			for i in ${!orderArr[@]}; do
				case "${orderArr[i]}" in
					$bid_id)
		        			echo "$(datelog)" "Starting task on node $i..."
						file=$(ls ./tasks | grep $i)
						startTaskOnDeal $deal_id $file
						orderArr[i]=launched
						;;
				esac		
				done
			done
			tasks_monitor
	else
		for i in ${!orderArr[@]}; do
			case "${orderArr[i]}" in
				$broken)
					echo "$(datelog)" "Creating new order for Node $i..."
					orderArr[i]=$(sonmcli order create ./orders/$tag_$i.yaml)
					;;
				$launched)
					rtaskid=$("$sonmcli" task list "$deal_id" --out json | jq -r 'to_entries[]|select(.value.status == 3)|.key' 2>/dev/null)
					if [ nodesArr[i] == false ] || [ ! -z "$rtaskid" ]; then
					echo "$(datelog)" "Creating new order for Node $i..."
					orderArr[i]=$(sonmcli order create ./orders/$tag_$i.yaml)
					fi
					;;
			esac	
		done
		echo "$datelog" "Waiting for deals"
		watch
	fi
}

startTaskOnDeal() { # dealid filename
	task_id=$( retry "$sonmcli" task start $1 ./tasks/$2 --out json | jq '.id' | sed -e 's/"//g')
	if [ -z "$task_id" ]; 
		then
			
			blacklist $1 
			node_num=$(cut -c $(($tag_length $2)+1)-)
			orderArr[$node_num]=broken
		else
			resolve_node_num_task $1 $task_id
			get_time $1 $task_id
			start_time[$node_num]=$time
		fi
}

closeDeal() {
	if [ ! -z $1 ]; then
		if [ "$(retry $sonmcli deal close "$(sed -e 's/^"//' -e 's/"$//' <<<"$1")")" ]; then
			echo "$(datelog)" "Closed deal $1"
		fi
	else
		echo "$(datelog)" "no deal id provided"
	fi
}

tasks_monitor() {
	for x in $("$sonmcli" deal list --out json | jq -r '.deals[].id' | sort -u); do
		dealid=$x
		rtaskid=$("$sonmcli" task list "$dealid" --out json | jq -r 'to_entries[]|select(.value.status == 3)|.key' 2>/dev/null)
		ftaskid=$("$sonmcli" task list "$dealid" --out json | jq -r 'to_entries[]|select(.value.status == 5)|.key' 2>/dev/null)
		if [ "$rtaskid" ]; then
			resolve_node_num_task $dealid $rtaskid
			get_time $dealid $rtaskid	
			fin_time=$time
			uptime=$(($fin_time-${start_time[$node_num]}))
			echo "$(datelog)" "Task $rtaskid on deal $dealid (Node $node_num) is running. Uptime is $uptime seconds"
		fi
		if [ "$ftaskid" ]; then
			get_time $dealid $ftaskid		
			fin_time=$time
			resolve_node_num_task $dealid $ftaskid
			uptime=$(($fin_time-${start_time[$node_num]}))
			if [ "$uptime" -gt "$eta" ]; then
				echo "$(datelog)" "Task $ftaskid on deal $dealid (Node $node_num) success. Fetching log, shutting down node"
				retry "$sonmcli" task logs "$dealid" "$ftaskid" > $node_num.log
				echo "$(datelog)" "Closing deal $dealid..."
				closeDeal $dealid
				nodesArr[$node_num]=true
				file=$(ls ./tasks | grep $node_num)
				rm orders/$file
				rm tasks/$file
			else
				blacklist $dealid
			fi
		fi
	done
	watch
}

valid_ip() {
	local ip=$1
	local stat=1

	if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		OIFS=$IFS
		IFS='.'
		ip=($ip)
		IFS=$OIFS
		[[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
		stat=$?
		if [[ ${ip[0]} == 127 || ${ip[0]} == 10 ]]; then stat=1; fi
		if [[ ${ip[0]} == 192 && ${ip[1]} == 168 ]]; then stat=1; fi
		if [[ ${ip[0]} == 172 && ${ip[1]} -gt 15 && ${ip[1]} -lt 32 ]]; then stat=1; fi

		#stat=$?
	fi
	return $stat
}

checkPublicIP() { # check if ip is public IPv4
	if valid_ip $1; then
		return 0
	else
		return 1
	fi
}
getIPofRunningTask() { # dealid
	if [ $# == 1 ]; then
		local dealid="$1"
		taskid=$("$sonmcli" task list "$dealid" --out json | jq -r 'to_entries[]|select(.value.status == 3)|.key' 2>/dev/null)
		for x in $("$sonmcli" task status $dealid $taskid --out=json | jq -r '.ports."26257/tcp".endpoints[].addr' 2>/dev/null); do
			ip=$(sed -e 's/^"//' -e 's/"$//' -e 's/"$//' <<<"$x")
			if checkPublicIP $ip; then
				#echo "$dealid/$taskid/$ip"
				echo "$ip"
			fi
		done

	else
		local deals=($(getDeals))
		local ips=()
		for x in "${deals[@]}"; do
			ips+=($(getIPofRunningTask $x))
		done

		echo ${ips[@]}
	fi

}

closeAllDeals() {
	deals=($(getDeals))
	if [ ! -z $deals ]; then
		echo "$(datelog)" "Closing ${#deals[@]} deal(s)"
		for x in "${deals[@]}"; do
			closeDeal $x
		done
	else
		echo "$(datelog)" "no deals to close"
	fi
}

getRunningTasksByDeal() {
	"$sonmcli" task list "$1"
}

stopAllRunningTasks() {
	for x in $("$sonmcli" deal list --out json | jq -r '.deals[].id' | sort -u); do
		dealid=$x
		taskid=$("$sonmcli" task list "$dealid" --out json | jq -r 'to_entries[]|select(.value.status == 3)|.key' 2>/dev/null)
		if [ $taskid ]; then
			echo "Stoping task $taskid on deal $dealid"
			"$sonmcli" task stop "$dealid" "$taskid"
		fi
	done
}

function contains() {
    local n=$#
    local value=${!n}
    for ((i=1;i < $#;i++)) 
	do
        if [ "${!i}" == "${value}" ]; then
            echo "true"
            return 0
        fi
    done
    echo "false"
    return 1
}

usage() {
	echo "SONM simple deal & task manager"
	echo ""
	echo "$0"
	echo -e "\\tstoptasks"
	echo -e "\\t\\tStop all running tasks"
	echo -e "\\tclosedeals"
	echo -e "\\t\\tClose all active deals"
	echo -e "\\twatch"
	echo -e "\\t\\tCreate orders, wait for deals, deploy tasks and watch cluster state"
	echo -e "\\tgetips"
	echo -e "\\t\\tGet IPs of all running tasks"
	echo ""
}

watch() {
if [ $(contains "${nodesArr[@]}" "false") == "true" ]; 
	then
	echo "$(datelog)" "Watching cluster..."
	deal_mon
	else
	echo "$(datelog)" "All nodes are finished their task, shutting down..."
	exit
	fi	
}

while [ "$1" != "" ]; do
	case "$1" in
	watch)
		load_cfg
		load_generator
		watch
		exit
		;;
	closedeals)
		closeAllDeals
		exit
		;;
	cancelorders)
		"$sonmcli" order purge
		exit
		;;
	getips)
		ips=($(getIPofRunningTask))
		for x in "${ips[@]}"; do
			echo "$x"
		done
		exit
		;;
	stoptasks)
		stopAllRunningTasks
		exit
		;;
	help | *)
		usage
		exit 1
		;;
	esac
done
