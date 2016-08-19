#!/bin/bash

tar -zxvf ping.tgz
chmod +x doPing.sh
if [ -e kill_pings.sh ]
then
 chmod +x kill_pings.sh
fi
chmod +x ping/*.sh

rm ping.tgz
rm install-ping.sh

