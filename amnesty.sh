set_sonmcli() {
	if [ -f "./sonmcli" ]; then
		sonmcli="./sonmcli"
	else
		sonmcli="sonmcli"
	fi
}


amnesty() {
	addrs=$($sonmcli blacklist list --out=json | jq '.addresses' | tr -d '"[],\0') 

	if [ $addrs != "null" ]; then
			echo 'Blaclisted suppliers: ' $addrs

			for i in $addrs
			do  
			$sonmcli blacklist remove $i && echo $i
			done

		else echo 'Blacklist is clean'

	fi
}

set_sonmcli
amnesty