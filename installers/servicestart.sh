#!/bin/bash
# When wireless client AP or Bridge mode is enabled, this script handles starting
# up network services in a specific order and timing to avoid race conditions.

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
NAME=raspapd
DESC="Service control for RaspAP"
CONFIGFILE="/etc/raspap/hostapd.ini"
DAEMONPATH="/lib/systemd/system/raspapd.service"
OPENVPNENABLED=$(pidof openvpn | wc -l)

positional=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -i|--interface)
    interface="$2"
    shift # past argument
    shift # past value
    ;;
    -s|--seconds)
    seconds="$2"
    shift
    shift
    ;;
    -a|--action)
    action="$2"
    shift
    shift
    ;;
esac
done
set -- "${positional[@]}"

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"

new_country_code=$(curl -s -H "Authorization: Bearer 9da1eb466ed052" https://ipinfo.io/json | jq -r ".country // empty")
old_country_code=$(grep ^country_code $HOSTAPD_CONF | cut -d "=" -f 2)

if [[ ! -z "$new_country_code" ]] && [[ "$old_country_code" != "$new_country_code" ]]; then
    sudo sed -i "s/country_code=$old_country_code/country_code=$new_country_code/" /etc/hostapd/hostapd.conf
    echo "Updated country code: $new_country_code"
fi

old_ssid=$(grep ^ssid $HOSTAPD_CONF | cut -d "=" -f 2)
rpi_serial=$(cat /proc/cpuinfo | grep Serial | cut -d ' ' -f 2)
new_ssid="isobox-$rpi_serial"

if [[ "$old_ssid" != "$new_ssid" ]]; then
    sed -i "s/ssid=$old_ssid/ssid=$new_ssid/" $HOSTAPD_CONF
    echo "Updated ssid: $new_ssid"
fi

old_hostname=$(hostname)
new_hostname="isobox-$rpi_serial"

if [[ "$old_hostname" != "$new_hostname" ]]; then
    echo $new_hostname >/etc/hostname
    sed -i "s/$old_hostname/$new_hostname/" /etc/hosts
    hostname $new_hostname
    echo "Updated hostname: $new_hostname"
fi

echo "Stopping network services..."
if [ $OPENVPNENABLED -eq 1 ]; then
    systemctl stop openvpn-client@client
fi
systemctl stop systemd-networkd
systemctl stop hostapd.service
systemctl stop dnsmasq.service
systemctl stop dhcpcd.service

if [ "${action}" = "stop" ]; then
    echo "Services stopped. Exiting."
    exit 0
fi

if [ -f "$DAEMONPATH" ] && [ ! -z "$interface" ]; then
    echo "Changing RaspAP Daemon --interface to $interface"
    sed -i "s/\(--interface \)[[:alnum:]]*/\1$interface/" "$DAEMONPATH"
fi

if [ -r "$CONFIGFILE" ]; then
    declare -A config
    while IFS=" = " read -r key value; do
        config["$key"]="$value"
    done < "$CONFIGFILE"

    if [ "${config[BridgedEnable]}" = 1 ]; then
        if [ "${interface}" = "br0" ]; then
            echo "Stopping systemd-networkd"
            systemctl stop systemd-networkd

            echo "Restarting eth0 interface..."
            ip link set down eth0
            ip link set up eth0

            echo "Removing uap0 interface..."
            iw dev uap0 del

            echo "Enabling systemd-networkd"
            systemctl start systemd-networkd
            systemctl enable systemd-networkd
        fi
    else
        echo "Disabling systemd-networkd"
        systemctl disable systemd-networkd

        ip link ls up | grep -q 'br0' &> /dev/null
        if [ $? == 0 ]; then
            echo "Removing br0 interface..."
            ip link set down br0
            ip link del dev br0
        fi

        if [ "${config[WifiAPEnable]}" = 1 ]; then
            if [ "${interface}" = "uap0" ]; then

                ip link ls up | grep -q 'uap0' &> /dev/null
                if [ $? == 0 ]; then
                    echo "Removing uap0 interface..."
                    iw dev uap0 del
                fi

                echo "Adding uap0 interface to ${config[WifiManaged]}"
                iw dev ${config[WifiManaged]} interface add uap0 type __ap
                # Bring up uap0 interface
                ifconfig uap0 up
            fi
        fi
    fi
fi

# Start services, mitigating race conditions
echo "Starting network services..."
systemctl start hostapd.service
sleep "${seconds}"

systemctl start dhcpcd.service
sleep "${seconds}"

systemctl start dnsmasq.service

if [ $OPENVPNENABLED -eq 1 ]; then
    systemctl start openvpn-client@client
fi

# @mp035 found that the wifi client interface would stop every 8 seconds
# for about 16 seconds. Reassociating seems to solve this
if [ "${config[WifiAPEnable]}" = 1 ]; then
    echo "Reassociating wifi client interface..."
    sleep "${seconds}"
    wpa_cli -i ${config[WifiManaged]} reassociate
fi

echo "RaspAP service start DONE"
