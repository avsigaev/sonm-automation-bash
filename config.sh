#cluster settings
	numberofnodes="3" # cluster size
	tag="bshtst" #cluster name, bid's and tasks will use it
	eta=20 # Task estimated time of arrival, sec 

#counterparty settings
	counterparty="" # optional, sets counterparty for orders to take, must be HEX(40) string. Will be removed automatically in case of error/not set
	identity="anonymous" # Identity level of the counterparty. Can be "anonymous", "registered", "identified" and "professional". 

#node config
	ramsize="256" # MB, integers only
	storagesize="1" # GB, integers only
	cpucores="1" #number of cores, integers only
	sysbenchsingle="500"
	sysbenchmulti="600"
	netdownload="10" # Mbits, integers only
	netupload="10" # Mbits, integers only
	price="0.002" # $ per hour

#network settings
	overlay=false # Indicates whether overlay networking is required, boolean only
	incoming=false # Indicates whether inbound connections are required and public IP should be present on worker, boolean only

#gpu config (optional). If not required, set gpucount="0"
	gpucount="0" #number of units
	gpumem="15" # GPU unit RAM,Gb, integers only
	ethhashrate="1" # MH/s, integers only


