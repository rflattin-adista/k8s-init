#! /bin/bash
mkdir /var/log/adista-monitor
printf "Memory\tDisk\tCPU\n" > /var/log/adista-monitor/general.log
while [ true ]
do
	DATE=$(date '+%Y-%m-%d')
	HOUR=$(date '+%H%M%S')
	TS="$DATE $HOUR	"
	if [ ! -d /var/log/adista-monitor/$DATE ] ; then
		mkdir /var/log/adista-monitor/$DATE
	fi
	MEMORY=$(free -m | awk 'NR==2{printf "%.2f%%\t\t", $3*100/$2 }')
	DISK=$(df -h | awk '$NF=="/"{printf "%s\t\t", $5}')
	top -bn1 -c > /var/log/adista-monitor/$DATE/$HOUR
	CPU=$(cat /var/log/adista-monitor/$DATE/$HOUR | grep load | awk '{printf "%.2f%%\t\t\n", $(NF-2)}')
	echo "$TS$MEMORY$DISK$CPU" >> /var/log/adista-monitor/general.log
	# Suppress sub-directory older than 30 days
	find /var/log/adista-monitor -type d -ctime +30 -exec /bin/rm -rf {} \;
	sleep 120
done
