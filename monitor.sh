#!/usr/bin/env bash

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

set_state()
{
	for (( i = 0; i < numberofnodes; i++ )); do
		state[$i]=0
	done
}

load_generator() {
	if [ -f "bid_gen.sh" ]; then
		. bid_gen.sh
		else
			exit 1
		fi
}

init() {
	if [ -d ./out/orders ]; then 
		echo 'Folder .out/orders already exists'
	else mkdir -p ./out/orders
		chmod -R 777 ./out/orders
	fi
	if [ -d ./out/tasks ]; then 
		echo 'Folder .out/tasks already exists'
	else mkdir -p ./out/tasks
		chmod -R 777 ./out/tasks
	fi

	load_cfg
	set_state
	set_sonmcli
	check_installed
}

datelog() {
	date '+%Y-%m-%d %H:%M:%S'
}

retry() {
	local n=1
	local max=3
	local delay=1
	while true; do
		echo "$@" && $@ && break || {
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

resolve_node_num(){ #deal_id
	node_num=$($sonmcli deal status $1 --expand --out json | jq '.bid.tag' | tr -d '"' | base64 --decode | tr -d '\0' | grep -o '[0-9]*')
}

resolve_ntag(){ #deal_id
	ntag=$($sonmcli deal status $1 --expand --out json | jq '.bid.tag' | tr -d '"' | base64 --decode | tr -d '\0')
}

check_state()
{
	state[0]=1
		s=$( echo "${state[@]}"| grep 0 )
		if [[  -n "$s" ]]; then
			check_orders	
		else	
			echo "$(datelog)" "All tasks are finished"
			exit
		fi
}

check_orders()
{
	local ch_o=$($sonmcli order list --timeout=2m --out json | grep -o '[0-9]*')
	local ch_d=$($sonmcli deal list --timeout=2m --out json | grep -o '[0-9]*')
	if [[ "$ch_o" != "" ]]; then
		echo "$(datelog)" "Waiting for deals..."
		sleep 10
	elif [[ "$ch_d" = "" ]]; then
		echo "$(datelog)" "No deals or orders found. Creating new orders..."
		load_generator	
	fi
}

get_deals()
{
	local ch_d=$($sonmcli deal list --timeout=2m --out json | grep -o '[0-9]*')
	if [[ "$ch_d" != "" ]]; then
		i=1
		for x in $("$sonmcli" deal list --out json | jq -r '.deals[].id' | sort -u);
			do
				dealArr+=($x)
			done
	else
		check_state	
	fi	

}

task_manager() #deal_id #task_id
{
	deal_id=$1 
	task_id=$2
	status=$( $sonmcli task status $deal_id $task_id --timeout=2m --out json | jq '.status' | tr -d '"')
	resolve_node_num $deal_id
	resolve_ntag $deal_id
	case $status in
		SPOOLING)
			echo "$(datelog)" "Task $task_id on deal $deal_id (Node $node_num) is uploading..."
			;;
		RUNNING)
			get_time $deal_id $task_id
			echo "$(datelog)" "Task $task_id on deal $deal_id (Node $node_num) is running. Uptime is $time seconds"
			;;
		BROKEN|FINISHED)
			get_time $deal_id $task_id
				if [ "$time" -gt "$eta" ]; 
					then
						echo "$(datelog)" "Task $task_id on deal $deal_id (Node $node_num) is finished. Uptime is $time seconds"
						echo "$(datelog)" "Task $task_id on deal $deal_id (Node $node_num) success. Fetching log, shutting down node..."
						"$sonmcli" task logs "$deal_id" "$task_id" > out/$ntag.log
						echo "$(datelog)" "Closing deal $deal_id..."
						retry closeDeal $deal_id
						state[$node_num]="1"
						sleep 10
					else
						blacklist $deal_id
				fi
			;;
		esac
}


task_valid() #deal_id 
{
	deal_id=$1
	resolve_node_num $deal_id
	resolve_ntag $deal_id
	ch_d=$($sonmcli task list $deal_id --timeout=2m --out json | grep -o '[0-9]*')
	if [[ "$ch_d" != "" ]]; then
			task_id=$( $sonmcli task list $deal_id --timeout=2m --out json | jq 'to_entries[] | '.key'' |tr -d '"')
			task_manager  $deal_id $task_id	
	else
			echo "$(datelog)" "Starting task on node $node_num..."
			task_file="out/tasks/$ntag.yaml"
			retry startTaskOnDeal $deal_id $task_file
	fi		
}

deal_manager()
{
	num="0"
	get_deals
	for deal_id in "${dealArr[@]}";
		do
			unset 'dealArr[$num]'
			num=$(($num+1))
			task_valid $deal_id
		done
	deal_manager
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

blacklist() { # dealid #file
		echo "$(datelog)" "Failed to start task on deal $1. Closing deal and blacklisting counterparty worker's address..."
		resolve_node_num $1
		retry sonmcli deal close $1 --blacklist worker
		echo "$(datelog)" "Node $node_num failure, new order will be created..."
		resolve_ntag $1
		bidfile= "out/orders/$ntag.yaml"
		order=$("$sonmcli" order create $bidfile --out json | jq '.id' | sed -e 's/"//g')
		echo "$(datelog)" "Order for Node $node_num is $order"
				
}

startTaskOnDeal() { # dealid filename
	set -x
	check=$(retry "$sonmcli" task start $1 $2 --timeout=2m --out json | jq '.id' | tr -d '"')
	
	if [ -z "$check" ]; 
		then			
			blacklist $1 
	fi
	set +x
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
	retry "$sonmcli" deal purge --timeout=2m
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
	deal_manager	
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
	retry)
		retry $2
		exit
		;;	
	help | *)
		usage
		exit 1
		;;
	esac
done

