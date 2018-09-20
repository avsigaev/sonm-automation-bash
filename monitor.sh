#!/usr/bin/env bash

eta=20

set_sonmcli() {
	if [ -f "./sonmcli" ]; then
		sonmcli="./sonmcli"
	else
		sonmcli="sonmcli"
	fi
}

required_vars=(tag ramsize storagesize cpucores sysbenchsingle sysbenchmulti netdownload netupload price numberofnodes identity incoming overlay)
missing_vars=()

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

load_generator() {
	if [ -f "bid_gen.sh" ]; then
		. bid_gen.sh
		else
			exit 1
		fi
}

init() {
	set_sonmcli
	check_installed
	load_cfg
	load_generator
}

datelog() {
	date '+%Y-%m-%d %H:%M:%S'
}

retry() {
	local n=1
	local max=3
	local delay=5
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

resolve_node_num(){ #deal_id
	sonmcli deal status $1 --expand --out json | jq '.bid.tag' | tr -d '"' | base64 --decode | tr -d '\0' >num.txt
	node_num=$( cat num.txt | grep -o '[0-9]*' )
	rm num.txt
}

resolve_ntag(){ #deal_id

	retry sonmcli deal status $1 --expand --out json | jq '.bid.tag' | tr -d '"' | base64 --decode | tr -d '\0' > num.txt
	ntag=$( cat num.txt )  
	echo "$ntag"
	rm num.txt
}

blacklist() { # dealid #file
		echo "$(datelog)" "Failed to start task on deal $1 and blacklisting counterparty worker's address..."
		resolve_node_num
		retry sonmcli deal close $1 --blacklist worker
		echo "$(datelog)" "Node $node_num failure, new order will be created..."
		resolve_ntag $1
		bidfile= "out/orders/$ntag.yaml"
		order=$("$sonmcli" order create $bidfile --out json | jq '.id' | sed -e 's/"//g')
		echo "$(datelog)" "Order for Node $node_num is $order"
				
}

startTaskOnDeal() { # dealid filename
	check=$(retry "$sonmcli" task start $1 $2 --out json | jq '.id' | sed -e 's/"//g' | grep -o '[0-9]*')
	
	if [ -z "$check" ]; 
		then			
			blacklist $1 
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

get_time() { #dealid taskid
	time=$($sonmcli task status $1 $2 --out json | jq '.uptime' | sed -e 's/"//g' )
	time=$(($time/1000000000))
}


check_deals() {
	ch_d=$("$sonmcli" deal list | grep "No deals found")
	ch_o=$("$sonmcli" order list | grep "No orders found")
	if [ ! -z "$ch_o" ] && [ ! -z "$ch_d" ];
	then
		echo "$(datelog)" "Cluster finished all tasks"
		exit

	fi
	if [ ! -z "$ch_d" ] && [ -z "$ch_o" ]; then
		echo "$(datelog)" "Waiting for deals..."
			watch
	fi
	if [ -z "$ch_d" ]; then
		deal_mon
	fi
}


deal_mon() { 
	for x in $("$sonmcli" deal list --out json | jq -r '.deals[].id' | sort -u); 
		do
			dealid=$x
			resolve_node_num $dealid
			resolve_ntag $dealid
			echo "$(datelog)" "Checking Deal $dealid - Node $node_num"
			tasks=$(retry "$sonmcli" task list $dealid --timeout=2m | grep "No active tasks" )
			if [ -z "$tasks" ]; 

			then
				taskid=$( $sonmcli task list $dealid --timeout=2m --out json | jq 'to_entries[] | '.key'' |tr -d '"')
				status=$( sonmcli task status $dealid $taskid --timeout=2m --out json | jq '.status' | tr -d '"')
				resolve_node_num $dealid
				case $status in
					SPOOLING)
						echo "$(datelog)" "Task $taskid on deal $dealid (Node $node_num) is uploading..."
					;;
					RUNNING)
						get_time $dealid $taskid
						echo "$(datelog)" "Task $taskid on deal $dealid (Node $node_num) is running. Uptime is $time seconds"
					;;
					BROKEN)
						get_time $dealid $taskid
						if [ "$time" -gt "$eta" ]; 
						then
							echo "$(datelog)" "Task $taskid on deal $dealid (Node $node_num) is finished. Uptime is $time seconds"
							echo "$(datelog)" "Task $taskid on deal $dealid (Node $node_num) success. Fetching log, shutting down node..."
							retry "$sonmcli" task logs "$dealid" "$taskid" > $ntag.log
							echo "$(datelog)" "Closing deal $dealid..."
							retry closeDeal $dealid
						else
							blacklist $dealid
						fi
					;;
				esac
			else
				echo "Starting task on node $node_num..."
				taskfile="out/tasks/$ntag.yaml"
				retry startTaskOnDeal $dealid $taskfile		
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
	echo "$(datelog)" "Watching cluster..."
	check_deals	
}

while [ "$1" != "" ]; do
	case "$1" in
	watch)
		init
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

