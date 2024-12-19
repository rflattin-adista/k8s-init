cp vmware-fix.service /usr/lib/systemd/system/vmware-fix.service 
chmod 755 vmware-fix.sh
cp vmware-fix.sh /root
systemctl daemon-reload
systemctl enable vmware-fix.service
systemctl start vmware-fix.service
systemctl status vmware-fix.service
