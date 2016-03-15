#!/bin/bash

# Stop on the first sign of trouble
set -e

if [ $UID != 0 ]; then
    echo "ERROR: Operation not permitted. Forgot sudo?"
    exit 1
fi

VERSION="spi"
if [[ $1 != "" ]]; then VERSION=$1; fi

echo "The Things Network Gateway installer"
echo "Version $VERSION"

echo "Enter user name in charge of the gateway [ttn]"
read GWUSER
if [[ $GWUSER == "" ]]; then GWUSER="ttn"; fi
PASSWORD1="X"
PASSWORD2="Y"
while  [[ $PASSWORD1 != $PASSWORD2 ]]
do
 echo "Enter password: "
 read PASSWORD1
 echo "Re-enter password: "
 read PASSWORD2
done

#prepare the user
sudo useradd $GWUSER --create-home --groups sudo
echo $GWUSER:$PASSWORD1 | sudo chpasswd 
##sudo adduser $GWUSER sudo

#prepare the OS
#sudo apt-get install -y deborphan
#sudo apt-get update -y
#assume Jessie Lite has been installes
##sudo apt-get purge xserver* ^x11 ^libx ^lx wolfram-engine -y
##sudo apt-get autoremove -q -y --purge raspberrypi-artwork xkb-data omxplayer penguinspuzzle sgml-base xml-core alsa-.* fonts-.* desktop-* gnome-.* cifs-.* samba-.* 
###sudo apt-get purge samba* -y
#sudo apt-get autoremove -y
#sudo apt-get upgrade -y
#sudo apt-get clean
#sudo apt-get autoremove -y --purge
#sudo apt-get autoremove --purge $(deborphan)
#sudo apt-get autoclean -y 
#sudo apt-get update -y 
#sudo apt-get upgrade -y

# change to gateway user
su - $GWUSER $PASSWORD1

# Update the gateway installer to the correct branch
echo "Updating installer files..."
OLD_HEAD=$(git rev-parse HEAD)
git fetch
git checkout -q $VERSION
git pull
NEW_HEAD=$(git rev-parse HEAD)

if [[ $OLD_HEAD != $NEW_HEAD ]]; then
    echo "New installer found. Restarting process..."
    exec "./install.sh" "$VERSION"
fi

# Retrieve gateway configuration for later
echo "Configure your gateway:"
printf "       Descriptive name [ttn-ic880a]:"
read GATEWAY_NAME
if [[ $GATEWAY_NAME == "" ]]; then GATEWAY_NAME="ttn-ic880a"; fi

printf "       Contact email: "
read GATEWAY_EMAIL

printf "       Latitude [0]: "
read GATEWAY_LAT
if [[ $GATEWAY_LAT == "" ]]; then GATEWAY_LAT=0; fi

printf "       Longitude [0]: "
read GATEWAY_LON
if [[ $GATEWAY_LON == "" ]]; then GATEWAY_LON=0; fi

printf "       Altitude [0]: "
read GATEWAY_ALT
if [[ $GATEWAY_ALT == "" ]]; then GATEWAY_ALT=0; fi


# Change hostname if needed
CURRENT_HOSTNAME=$(hostname)
NEW_HOSTNAME="ttn-gateway"

if [[ $NEW_HOSTNAME != $CURRENT_HOSTNAME ]]; then
    echo "Updating hostname to '$NEW_HOSTNAME'..."
    hostname $NEW_HOSTNAME
    echo $NEW_HOSTNAME > /etc/hostname
    sed -i "s/$CURRENT_HOSTNAME/$NEW_HOSTNAME/" /etc/hosts
fi

# Check dependencies
echo "Installing dependencies..."
apt-get install -y swig python-dev

# Install LoRaWAN packet forwarder repositories
INSTALL_DIR="/opt/ttn-gateway"
if [ ! -d "$INSTALL_DIR" ]; then mkdir $INSTALL_DIR; fi
pushd $INSTALL_DIR

# Build WiringPi
if [ ! -d wiringPi ]; then
    git clone git://git.drogon.net/wiringPi
    pushd wiringPi
else
    pushd wiringPi
    git reset --hard
    git pull
fi

./build

popd

# Build LoRa gateway app
if [ ! -d lora_gateway ]; then
    git clone https://github.com/TheThingsNetwork/lora_gateway.git
    pushd lora_gateway
else
    pushd lora_gateway
    git reset --hard
    git pull
fi

sed -i -e 's/PLATFORM= kerlink/PLATFORM= imst_rpi/g' ./libloragw/library.cfg

make

popd

# Build packet forwarder
if [ ! -d packet_forwarder ]; then
    git clone https://github.com/TheThingsNetwork/packet_forwarder.git
    pushd packet_forwarder
else
    pushd packet_forwarder
    git pull
    git reset --hard
fi

make

popd

# Symlink poly packet forwarder
if [ ! -d bin ]; then mkdir bin; fi
if [ -f ./bin/poly_pkt_fwd ]; then rm ./bin/poly_pkt_fwd; fi
ln -s $INSTALL_DIR/packet_forwarder/poly_pkt_fwd/poly_pkt_fwd ./bin/poly_pkt_fwd
cp -f ./packet_forwarder/poly_pkt_fwd/global_conf.json ./bin/global_conf.json

echo -e "{\n\t\"gateway_conf\": {\n\t\t\"gateway_ID\": \"0000000000000000\",\n\t\t\"servers\": [ { \"server_address\": \"croft.thethings.girovito.nl\", \"serv_port_up\": 1700, \"serv_port_down\": 1701, \"serv_enabled\": true } ],\n\t\t\"ref_latitude\": $GATEWAY_LAT,\n\t\t\"ref_longitude\": $GATEWAY_LON,\n\t\t\"ref_altitude\": $GATEWAY_ALT,\n\t\t\"contact_email\": \"$GATEWAY_EMAIL\",\n\t\t\"description\": \"$GATEWAY_NAME\" \n\t}\n}" >./bin/local_conf.json

# Reset gateway ID based on MAC
./packet_forwarder/reset_pkt_fwd.sh start ./bin/local_conf.json

popd

echo "Installation completed."

# Start packet forwarder as a service
cp ./start.sh $INSTALL_DIR/bin/
cp ./ttn-gateway.service /lib/systemd/system/
systemctl enable ttn-gateway.service

echo "The system will reboot in 5 seconds..."
sleep 5
shutdown -r now
