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
			tag="$1_$(($number))"
			bidfile=$(generateBidFile $tag $ramsize $storagesize $cpucores $sysbenchsingle $sysbenchmulti $netdownload $netupload $price $counterparty $gpucount $gpumem $ethhashrate $overlay $incoming $identity)
			echo "$(datelog)" "Creating order for Node number $number"
			orderArr[$number]=$("$sonmcli" order create $bidfile --out json | jq '.id' | sed -e 's/"//g')
			nodesArr[$number]=false
			echo "$(datelog)" "Creating task file for Node number $number"
			task_gen $tag $number
		done 
	else
		return 1
	fi

}

generateBidFile() { # tag ramsize storagesize cpucores sysbenchsingle sysbenchmulti netdownload netupload price
	if [ ! -z $1 ]; then
		tag=$1
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
	if [ -f "orders/bid.yaml.template" ]; then
		sed -e "s/\${tag}/$tag/" \
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
orders/bid.yaml.template >orders/$tag.yaml && echo "orders/$tag.yaml"
		sed -i "s|counterparty: error||g" orders/$tag.yaml
	fi
}

task_gen() { #tag
	tag=$1
	number=$2
	if [ -f "tasks/task.yaml.template" ]; then
		cp tasks/task.yaml.template tasks/$tag.yaml
		sed -i "s/\${tag}/$tag/g" tasks/$tag.yaml
		sed -i "s/\${env_tag}/$number/g" tasks/$tag.yaml
		cat tasks/$tag.yaml
		
	fi
}

if [ ! -z "counterparty" ]; then
	counterparty="not_set"
fi

createOrders $tag $numberoforders $ramsize $storagesize $cpucores $sysbenchsingle $sysbenchmulti $netdownload $netupload $price $counterparty $gpucount $gpumem $ethhashrate $overlay $incoming $identity
tag_length=$(expr length "$tag")