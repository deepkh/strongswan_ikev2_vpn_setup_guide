#!/bin/bash

set -e

CERT_PASSWORD=12345678
ROOTCA_PREFIX=ikev2_rootca
ROOT_DNS=netsync.tv
SERVER_PREFIX=ikev2_serverca
SERVER_DNS=ikev2.netsync.tv
SERVER_DNS6=deb6.netsync.tv
IP_DNS1=192.168.1.22
IP_DNS2=127.0.0.1

CLIENT_PREFIX=deb_clientca
CLIENT_CN="deepkh@ikev2.netsync.tv"

IPSEC_EAP_USERNAME=username
IPSEC_EAP_PASSWORD=password

do_func() {
	echo ""
	echo "####### $1 #######"
	func=$2
	shift				#shift $1
	shift				#shift $2
	($func "$@")
}

strongswan_packages_install() {
	sudo apt-get install strongswan strongswan-swanctl libcharon-extra-plugins strongswan-pki iptables-persistent libstrongswan-extra-plugins libstrongswan-standard-plugins libcharon-extra-plugins resolvconf --no-install-recommends
}

# Generate RootCA's X509 Certificate
rootca_gen() {
	openssl genrsa -aes256 -out $ROOTCA_PREFIX.key -passout pass:$CERT_PASSWORD 2048
	openssl req -new -sha256 -key $ROOTCA_PREFIX.key -subj "/O=Netsync.tv/CN=iKEv2 VPN Personal Root Certificate" -config <(cat /etc/ssl/openssl.cnf ) -out $ROOTCA_PREFIX.csr -extensions v3_ca -passin pass:$CERT_PASSWORD
	openssl x509 -req -in $ROOTCA_PREFIX.csr -out $ROOTCA_PREFIX.crt -days 10950 -signkey $ROOTCA_PREFIX.key -extfile /etc/ssl/openssl.cnf -extensions v3_ca -passin pass:$CERT_PASSWORD
}

# Generate StrongSwan Server's X509 Certificate
serverca_gen() {
	openssl genrsa -out $SERVER_PREFIX.key 2048
	openssl req -new -sha256 -key $SERVER_PREFIX.key -subj "/O=Netsync.tv/CN=$SERVER_DNS" -config <(cat openssl.cnf ) -out $SERVER_PREFIX.csr -extensions server_cert2 
	openssl x509 -req -in $SERVER_PREFIX.csr -CA $ROOTCA_PREFIX.crt -CAkey $ROOTCA_PREFIX.key -CAcreateserial -out $SERVER_PREFIX.crt -days 3650 -extfile <(cat openssl.cnf <(printf "subjectAltName=DNS:$SERVER_DNS,DNS:$SERVER_DNS6,IP:$IP_DNS1,IP:$IP_DNS2")) -extensions server_cert2 -passin pass:$CERT_PASSWORD
}

# Generate StrongSwan Client's X509 Certificate
clientca_gen() {
	openssl genrsa -out $CLIENT_PREFIX.key 2048
	openssl req -new -sha256 -key $CLIENT_PREFIX.key -subj "/CN=$CLIENT_CN" -config <(cat openssl.cnf ) -out $CLIENT_PREFIX.csr -extensions server_cert2 
	openssl x509 -req -in $CLIENT_PREFIX.csr -CA $ROOTCA_PREFIX.crt -CAkey $ROOTCA_PREFIX.key -CAcreateserial -out $CLIENT_PREFIX.crt -days 3650 -extfile <(cat openssl.cnf <(printf "subjectAltName=DNS:$CLIENT_CN")) -extensions server_cert2 -passin pass:$CERT_PASSWORD

	#generate PKCS#12(.p12) 
	openssl pkcs12 -export -out $CLIENT_PREFIX.p12 -inkey $CLIENT_PREFIX.key -in $CLIENT_PREFIX.crt -certfile $ROOTCA_PREFIX.crt
}


# Install StrongSwan Server's X509 Certificate to /etc/ipsec.d/private/ and /etc/ipsec.d/certs/ 
serverca_install() {
	sudo cp $SERVER_PREFIX.key /etc/ipsec.d/private
	sudo cp $SERVER_PREFIX.crt /etc/ipsec.d/certs
	#no need put client.key to private due to public key auth (use public key to encrtpy, private key to decrypt)
	#sudo cp $CLIENT_PREFIX.key /etc/ipsec.d/private
	sudo cp $CLIENT_PREFIX.crt /etc/ipsec.d/certs
}

# Setting /etc/ipsec.secrets
ipsec_secrets() {
	sudo bash -c "cat > /etc/ipsec.secrets2 << EOF1
$SERVER_DNS : RSA \"$SERVER_PREFIX.key\"
$IPSEC_EAP_USERNAME : EAP \"$IPSEC_EAP_PASSWORD\"
#include /var/lib/strongswan/ipsec.secrets.inc
EOF1"
}

# Setting /etc/ipsec.conf
ipsec_conf() {
	sudo bash -c "cat > /etc/ipsec.conf2 << EOF2
config setup
    charondebug=\"ike 2, knl 3, cfg 0\"
    uniqueids=no

conn ikev2-vpn
    auto=add
    compress=no
    type=tunnel
    keyexchange=ikev2
    fragmentation=yes
    forceencaps=yes
    #ike=aes256-sha1-modp1024,3des-sha1-modp1024!
    #esp=aes256-sha1,3des-sha1!
    ike=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024! # Win7 is aes256, sha-1, modp1024; iOS is aes256, sha-256, modp1024; OS X is 3DES, sha-1, modp1024
    esp=aes256-sha256,aes256-sha1,3des-sha1!                          # Win 7 is aes256-sha1, iOS is aes256-sha256, OS X is 3des-shal1
    dpdaction=clear
    dpddelay=300s
    rekey=no
    #Server
    left=%any
    leftid=@$SERVER_DNS
    leftcert=$SERVER_PREFIX.crt
    leftsendcert=always
    leftsubnet=0.0.0.0/0
    #Client
    right=%any
    rightid=%any
    rightdns=8.8.8.8,8.8.4.4
    rightsourceip=10.10.10.0/24
    #rightcert=VPNCA3.crt       can't working, instead of following 3 items
    rightauth=eap-mschapv2
    rightsendcert=never
    eap_identity=%identity
EOF2"
}

strongswan_conf() {
	sudo bash -c "cat > /etc/strongswan.conf2 << EOF3
charon {
    #duplicheck.enable = no
    load = eap-mschapv2 
    install_virtual_ip = yes
    dns1 = 8.8.8.8
    dns2 = 8.8.4.4
    load_modular = yes
    plugins {
        include strongswan.d/charon/*.conf
    }
}

include strongswan.d/*.conf
EOF3"
}

iptables_install() {
	sudo cp strongswan_iptables.sh /etc/network/if-up.d/iptables
	sudo chmod +x /etc/network/if-up.d/iptables
	sudo /etc/network/if-up.d/iptables
}

strongswan_restart() {
	set +e
	sudo systemctl enable strongswan-starter
	sudo systemctl restart strongswan-starter
	sudo ipsec restart
	sleep 1
	strongswan_status
}

strongswan_status() {
	sudo ipsec statusall
}

strongswan_log() {
  sudo journalctl -u strongswan-starter
}

clear() {
	rm *.csr *.key *.crt *.srl 2> /dev/null
}

install() {
	do_func "Install StrongSwan packages" strongswan_packages_install 

	if [ ! -f $ROOTCA_PREFIX.key ] && [ ! -f $ROOTCA_PREFIX.crt ];then
		do_func "Generating RootCA's X509 Certificate" rootca_gen 
	fi

	if [ ! -f $SERVER_PREFIX.csr ] && [ ! -f $SERVER_PREFIX.csr ];then
		do_func "Generating StrongSwan Server's X509 Certificate" serverca_gen
	fi

	do_func "Install StrongSwan Server's X509 Certificate" serverca_install
	do_func "Setting /etc/ipsec.conf" ipsec_conf
	do_func "Setting /etc/ipsec.secrets" ipsec_secrets
	do_func "Setting /etc/strongswan.conf" strongswan_conf
	do_func "Setting /etc/network/if-up.d/iptables " iptables_install
	do_func "Restart StrongSwan" strongswan_restart
}

$@
