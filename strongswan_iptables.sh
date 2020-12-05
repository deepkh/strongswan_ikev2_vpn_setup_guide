#!/bin/bash
iptables='/sbin/iptables'
ALL_ACCEPT_TCP_PORTS="80 443 5566 8080 8888 8800"
WHITE_ADDRESS="192.168.6.0/24 192.168.4.0/24 10.10.10.0/24"
WHITE_ACCEPT_TCP_PORTS="22 80 111 139 443 445 2049 2222 5566 5900 5901 5902 8080 8888 8800"
$iptables -F
$iptables -X
$iptables -Z
$iptables -P INPUT ACCEPT
$iptables -P OUTPUT ACCEPT
$iptables -P FORWARD ACCEPT
$iptables -t nat -F
$iptables -t nat -X
$iptables -t nat -Z
$iptables -t nat -P PREROUTING ACCEPT
$iptables -t nat -P POSTROUTING ACCEPT
$iptables -t nat -P OUTPUT ACCEPT

# Allow 10.10.10.0/24 INPUT all
$iptables -A INPUT -s 10.10.10.0/24 -j ACCEPT
$iptables -A INPUT -s 192.168.4.0/24 -j ACCEPT
$iptables -A INPUT -s 192.168.6.0/24 -j ACCEPT

# Allows all loopback (lo0) traffic and drop all traffic to 127/8 that doesn't use lo0
$iptables -A INPUT -i lo -j ACCEPT
$iptables -A INPUT ! -i lo -d 127.0.0.0/8 -j REJECT

# Accepts all established inbound connections
$iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allows all outbound traffic
# You could modify this to only allow certain traffic
$iptables -A OUTPUT -j ACCEPT

# Allows Cloudflare ipv4 address by using ipset
#ipset create cf hash:net
#for x in $(curl https://www.cloudflare.com/ips-v4); do ipset add cf $x; done
#iptables -A INPUT -m set --match-set cf src -p tcp -m multiport --dports http,https -j ACCEPT

#### (disable only for cloudflare to incoming by above line) Allows all inbound tcp port
for PORT in $ALL_ACCEPT_TCP_PORTS
do
    $iptables -A INPUT -p tcp --dport $PORT -j ACCEPT
done

# Allows all inbound tcp port with white address
for ADDR in $WHITE_ADDRESS
do
        for PORT in $WHITE_ACCEPT_TCP_PORTS
        do
                $iptables -A INPUT -p tcp -s $ADDR --dport $PORT -j ACCEPT
                $iptables -A INPUT -p icmp -s $ADDR -m icmp --icmp-type 8 -j ACCEPT
        done
done

########### fd limits ##########
sysctl -w fs.file-max="9999999"
sysctl -w fs.nr_open="9999999"
sysctl -w net.core.netdev_max_backlog="4096"
sysctl -w net.core.rmem_max="16777216"
sysctl -w net.core.somaxconn="65535"
sysctl -w net.core.wmem_max="16777216"
sysctl -w net.ipv4.ip_local_port_range="1025       65535"
sysctl -w net.ipv4.tcp_fin_timeout="30"
sysctl -w net.ipv4.tcp_keepalive_time="30"
sysctl -w net.ipv4.tcp_max_syn_backlog="20480"
sysctl -w net.ipv4.tcp_max_tw_buckets="400000"
sysctl -w net.ipv4.tcp_no_metrics_save="1"
sysctl -w net.ipv4.tcp_syn_retries="2"
sysctl -w net.ipv4.tcp_synack_retries="2"
sysctl -w net.ipv4.tcp_tw_recycle="1"
sysctl -w net.ipv4.tcp_tw_reuse="1"
sysctl -w vm.min_free_kbytes="65536"
sysctl -w vm.overcommit_memory="1"

#### ipsec: allow server
ALL_ACCEPT_IPSECS_UDP_PORTS="500 4500"
for PORT in $ALL_ACCEPT_IPSECS_UDP_PORTS
do
    $iptables -A INPUT -p udp --dport $PORT -j ACCEPT
done


#### ipsec: allow forward
#### Also need to add routing table at LAN 192.168.4.0 as following
#### route ADD 10.10.10.0 MASK 255.255.255.0 192.168.4.2
$iptables -A FORWARD --match policy --pol ipsec --dir in  --proto esp -s 10.10.10.0/24 -j ACCEPT
$iptables -A FORWARD --match policy --pol ipsec --dir out --proto esp -d 10.10.10.0/24 -j ACCEPT

#### ipsec: masquerade to internet
$iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o ppp0 -j MASQUERADE

#### ipsec: allow IP forward
sysctl -w net.ipv4.ip_forward=1

# Reject all other inbound - default deny unless explicitly allowed policy:
$iptables -A INPUT -p icmp -m icmp --icmp-type 8 -j DROP
$iptables -A INPUT -j DROP
$iptables -A FORWARD -j REJECT

