cp monitor.service /usr/lib/systemd/system/monitor.service 
chmod 755 monitor.sh
cp monitor.sh /root
systemctl daemon-reload
systemctl enable monitor.service
systemctl start monitor.service
systemctl status monitor.service
