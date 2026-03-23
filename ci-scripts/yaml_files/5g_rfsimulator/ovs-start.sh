#!/bin/bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p /var/run/openvswitch /var/log/openvswitch /etc/openvswitch

if [ ! -f /etc/openvswitch/conf.db ]; then
  echo "[OVS] Creating /etc/openvswitch/conf.db ..."
  ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
fi

echo "[OVS] Starting ovsdb-server..."
/usr/sbin/ovsdb-server \
  --remote=punix:/var/run/openvswitch/db.sock \
  --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
  --pidfile --detach \
  --log-file=/var/log/openvswitch/ovsdb-server.log \
  /etc/openvswitch/conf.db

echo "[OVS] Waiting for db.sock..."
for i in $(seq 1 50); do
  [ -S /var/run/openvswitch/db.sock ] && break
  sleep 0.2
done
[ -S /var/run/openvswitch/db.sock ] || { echo "[OVS] ERROR: db.sock not created"; ls -la /var/run/openvswitch; exit 1; }

echo "[OVS] Initializing OVS database..."
/usr/bin/ovs-vsctl --no-wait init

echo "[OVS] Starting ovs-vswitchd..."
/usr/sbin/ovs-vswitchd \
  --pidfile --detach \
  --log-file=/var/log/openvswitch/ovs-vswitchd.log \
  --unixctl=/var/run/openvswitch/ovs-vswitchd.ctl

sleep 2

echo "[OVS] Running ovs-init..."
bash -x /ovs-init.sh 2>&1 | tee /var/log/openvswitch/ovs-init.log

echo "[OVS] Done. Tailing ovs-vswitchd log..."
tail -f /var/log/openvswitch/ovs-vswitchd.log
