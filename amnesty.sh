for i in $(sonmcli blacklist list --out=json | jq '.addresses' | tr -d '"[],\0') 
do 
sonmcli blacklist remove $i && echo $i
done
