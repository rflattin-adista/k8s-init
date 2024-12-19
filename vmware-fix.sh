ethtool -K enp11s0 tx-udp_tnl-segmentation off
ethtool -K enp11s0 tx-udp_tnl-csum-segmentation off

ethtool -K ens192 tx-udp_tnl-segmentation off
ethtool -K ens192 tx-udp_tnl-csum-segmentation off

ethtool -K eth0 tx-udp_tnl-segmentation off
ethtool -K eth0 tx-udp_tnl-csum-segmentation off
