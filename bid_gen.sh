#!/usr/bin/env bash

numberoforders=$numberofnodes

validate() { #validate counterparty address via regexp
	if ! [[ ${1} =~ ^0x[a-fA-F0-9]{40}$ ]]; then
	        echo "Counterparty address is not valid ethereum address or not specified. Removing counterparty settings..."
	        counterparty="error"
	else
		counterparty=${1}
		echo "Set specified counterparty address $1"	
    	fi
}


createOrders() { # tag numberoforders ramsize storagesize cpucores sysbenchsingle sysbenchmulti netdownload netupload price
	if [ $# == 17 ]; then
		tag=$1
		numberoforders=$2
		ramsize=$3
		storagesize=$4
		cpucores=$5
		sysbenchsingle=$6
		sysbenchmulti=$7
		cpucores=$5
		netdownload=$8
		netupload=$9
		price=${10}
		gpucount=${12}
		validate ${11}
		gpumem=${13}
		ethhashrate=${14}
		overlay=${15}
		incoming=${16}
		identity=${17}
		if [ "${gpucount}" -eq "0" ]; then
			gpumem=0
			ethhashrate=0
		fi	
		for ((number=1;  number <= numberoforders ; number++))
		do
			ntag="$1_$(($number))"
			bidfile=$(generateBidFile $ntag $ramsize $storagesize $cpucores $sysbenchsingle $sysbenchmulti $netdownload $netupload $price $counterparty $gpucount $gpumem $ethhashrate $overlay $incoming $identity)
			echo "$(datelog)" "Creating order for Node number $number"
			order=$("$sonmcli" order create $bidfile --out json | jq '.id' | sed -e 's/"//g')
			echo "$(datelog)" "Order for Node $node_num is $order"
			echo "$(datelog)" "Creating task file for Node number $number"
			task_gen $ntag 
		done 
	else
		return 1
	fi

}

generateBidFile() { # tag ramsize storagesize cpucores sysbenchsingle sysbenchmulti netdownload netupload price
	if [ ! -z $1 ]; then
		ntag=$1
	fi
	if [ ! -z $2 ]; then
		ramsize=$(($2 * 1024 * 1024))
	fi
	if [ ! -z $3 ]; then
		storagesize=$(($3 * 1024 * 1024 * 1024))
	fi
	if [ ! -z $4 ]; then
		cpucores=$4
	fi
	if [ ! -z $7 ] && [ ! -z $8 ] && [ ! -z $9 ]; then
		sysbenchsingle=$5
		sysbenchmulti=$6
		netdownload=$(($7 * 1024 * 1024))
		netupload=$(($8 * 1024 * 1024))
		price=$9
	fi
	if [ ! -z ${10} ]; then
		counterparty=${10}
	fi
	if [ ! -z ${11} ] && [ ! -z ${12} ] && [ ! -z ${13} ]; then
		gpucount=${11} 
		gpumem=$((${12}* 1024 * 1024)) 
		ethhashrate=$((${13}* 1000 * 1000))
	fi
	if [ ! -z ${14} ] && [ ! -z ${15} ]; then
		overlay=${14}
		incoming=${15}
	fi
	if [ ! -z ${16} ] ; then
		identity=${16}
	fi
	if [ -f "bid.yaml.template" ]; then
		sed -e "s/\${tag}/$ntag/" \
			-e "s/\${ramsize}/$ramsize/" \
			-e "s/\${storagesize}/$storagesize/" \
			-e "s/\${cpucores}/$cpucores/" \
			-e "s/\${sysbenchsingle}/$sysbenchsingle/" \
			-e "s/\${sysbenchmulti}/$sysbenchmulti/" \
			-e "s/\${netdownload}/$netdownload/" \
			-e "s/\${netupload}/$netupload/" \
			-e "s/\${price}/$price/" \
			-e "s/\${counterparty}/$counterparty/" \
			-e "s/\${gpucount}/$gpucount/" \
			-e "s/\${gpumem}/$gpumem/" \
			-e "s/\${ethhashrate}/$ethhashrate/" \
			-e "s/\${overlay}/$overlay/" \
			-e "s/\${incoming}/$incoming/" \
			-e "s/\${identity}/$identity/" \
bid.yaml.template >out/orders/$ntag.yaml && echo "out/orders/$ntag.yaml"
		sed -i "s|counterparty: error||g" out/orders/$ntag.yaml
		chmod +x out/orders/$ntag.yaml
	fi
}

task_gen() { #tag
	ntag=$1
	if [ -f "task.yaml.template" ]; then
		cp task.yaml.template out/tasks/$ntag.yaml
		sed -i "s/\${tag}/$ntag/g" out/tasks/$ntag.yaml
		sed -i "s/\${env_tag}/$ntag/g" out/tasks/$ntag.yaml
		chmod +x out/tasks/$ntag.yaml		
	fi
}

if [ ! -z "counterparty" ]; then
	counterparty="not_set"
fi

createOrders $tag $numberoforders $ramsize $storagesize $cpucores $sysbenchsingle $sysbenchmulti $netdownload $netupload $price $counterparty $gpucount $gpumem $ethhashrate $overlay $incoming $identity

