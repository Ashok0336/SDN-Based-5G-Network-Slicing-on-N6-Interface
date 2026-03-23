#!/bin/bash
set -euo pipefail

UPF_CONT=${UPF_CONT:-rfsim5g-oai-upf}
EDN_CONT=${EDN_CONT:-rfsim5g-oai-ext-dn}
UPF_N6_IF=${UPF_N6_IF:-n6ovs0}
EDN_IF=${EDN_IF:-dn0}
ONOS_CTRL=${ONOS_CTRL:-192.168.71.160:6653}

BR=br-n6
V_UPF_HOST=v-upf-host
V_UPF_CONT=v-upf
V_EDN_HOST=v-edn-host
V_EDN_CONT=v-edn

in_ns () { nsenter -t "$1" -n -- bash -lc "$2"; }

need_cmd () {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ovs-init] ERROR: required command '$1' not found" >&2
    exit 1
  }
}

wait_pid () {
  local c="$1"
  local pid="0"
  for i in {1..60}; do
    pid=$(docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null || echo 0)
    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
      echo "$pid"
      return 0
    fi
    echo "[ovs-init] waiting for PID of $c ..."
    sleep 1
  done
  echo "[ovs-init] ERROR: Could not get PID for container $c (not running?)" >&2
  exit 1
}

echo "[ovs-init] Using UPF_CONT=$UPF_CONT EDN_CONT=$EDN_CONT ONOS_CTRL=$ONOS_CTRL"

need_cmd docker
need_cmd nsenter
need_cmd ovs-vsctl
need_cmd ovs-ofctl
need_cmd ip

# 1) Prepare bridge
ovs-vsctl --may-exist add-br "$BR"
ovs-vsctl set bridge "$BR" datapath_type=netdev
ovs-vsctl set-fail-mode "$BR" secure
ovs-vsctl set-controller "$BR" "tcp:$ONOS_CTRL"
ip link set "$BR" up || true

# 2) Delete stale links in host netns
ip link del "$V_UPF_HOST" 2>/dev/null || true
ip link del "$V_EDN_HOST" 2>/dev/null || true
ip link del "$V_UPF_CONT" 2>/dev/null || true
ip link del "$V_EDN_CONT" 2>/dev/null || true

# 3) Create veth pairs (idempotent)
ip link add "$V_UPF_HOST" type veth peer name "$V_UPF_CONT"
ip link add "$V_EDN_HOST" type veth peer name "$V_EDN_CONT"

# 4) Move peer ends into namespaces
UPF_PID=$(wait_pid "$UPF_CONT")
EDN_PID=$(wait_pid "$EDN_CONT")
echo "[ovs-init] UPF pid=$UPF_PID  EDN pid=$EDN_PID"

ip link set "$V_UPF_CONT" netns "$UPF_PID"
ip link set "$V_EDN_CONT" netns "$EDN_PID"

# 5) Rename + configure inside namespaces
# UPF: create N6 interface as $UPF_N6_IF and assign IP 192.168.72.134/26
in_ns "$UPF_PID" "
  ip link del $UPF_N6_IF 2>/dev/null || true;
  ip link set $V_UPF_CONT name $UPF_N6_IF;
  ip addr flush dev $UPF_N6_IF || true;
  ip addr add 192.168.72.134/26 dev $UPF_N6_IF;
  ip link set $UPF_N6_IF up
"

# Ext-DN: connect to OVS as $EDN_IF and assign data-plane IP.
in_ns "$EDN_PID" "
  ip link del $EDN_IF 2>/dev/null || true;
  ip link set $V_EDN_CONT name $EDN_IF;
  ip addr flush dev $EDN_IF || true;
  ip addr add 192.168.72.135/26 dev $EDN_IF;
  ip link set $EDN_IF up
"

# 6) Bring up host ends and add to bridge
ip link set "$V_UPF_HOST" up
ip link set "$V_EDN_HOST" up

ovs-vsctl --if-exists del-port "$BR" "$V_UPF_HOST"
ovs-vsctl --if-exists del-port "$BR" "$V_EDN_HOST"
ovs-vsctl --may-exist add-port "$BR" "$V_UPF_HOST"
ovs-vsctl --may-exist add-port "$BR" "$V_EDN_HOST"

echo "[ovs-init] Bridge $BR ready with UPF=$V_UPF_HOST, EDN=$V_EDN_HOST"

# 7) Create QoS queues on the Ext-DN egress port (v-edn-host)
# Queue 1: eMBB (50-100 Mb/s), Queue 2: URLLC (10-20 Mb/s), Queue 3: mMTC (1-5 Mb/s)
# Clear any previously attached QoS reference on this port before recreating.
ovs-vsctl --if-exists clear port "$V_EDN_HOST" qos
ovs-vsctl -- set port "$V_EDN_HOST" qos=@newqos \
  -- --id=@newqos create qos type=linux-htb other-config:max-rate=120000000 \
     queues:1=@q1 queues:2=@q2 queues:3=@q3 \
  -- --id=@q1 create queue other-config:min-rate=50000000 other-config:max-rate=100000000 \
  -- --id=@q2 create queue other-config:min-rate=10000000 other-config:max-rate=20000000 \
  -- --id=@q3 create queue other-config:min-rate=1000000  other-config:max-rate=5000000

echo "[ovs-init] QoS queues created on port $V_EDN_HOST"

# 8) Require stable ONOS controller connection (ONOS owns policy rules).
ovs-vsctl set bridge "$BR" protocols=OpenFlow13
stable=0
for i in {1..60}; do
  if ovs-vsctl show | grep -q "is_connected: true"; then
    stable=$((stable + 1))
    if [ "$stable" -ge 3 ]; then
      break
    fi
  else
    stable=0
  fi
  echo "[ovs-init] waiting for stable ONOS controller connection..."
  sleep 1
done
if [ "$stable" -lt 3 ]; then
  echo "[ovs-init] ERROR: ONOS controller did not reach stable connected state" >&2
  exit 1
fi

echo "[ovs-init] ONOS controller is stable; bridge/ports/queues are ready for ONOS policy install."
