#!/bin/bash
set -euo pipefail

ONOS_IP=${ONOS_IP:-127.0.0.1}
ONOS_PORT=${ONOS_PORT:-8181}
AUTH=${AUTH:-onos:rocks}

echo "[1] Waiting for ONOS REST..."
until curl -s -u "$AUTH" "http://$ONOS_IP:$ONOS_PORT/onos/v1/devices" >/dev/null; do
  sleep 2
done

echo "[2] Getting OVS device ID..."
DEVICE_ID=$(curl -s -u "$AUTH" "http://$ONOS_IP:$ONOS_PORT/onos/v1/devices" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    dev=[x['id'] for x in d.get('devices',[]) if x.get('available',False)]; \
    print(dev[0] if dev else '')")

if [ -z "$DEVICE_ID" ]; then
  echo "ERROR: No available device found in ONOS."
  exit 1
fi

echo "DEVICE_ID=$DEVICE_ID"

# Helper: push a flow
push_flow () {
  local FLOW_JSON="$1"
  curl -s -u "$AUTH" -H "Content-Type: application/json" \
    -X POST "http://$ONOS_IP:$ONOS_PORT/onos/v1/flows/$DEVICE_ID" \
    -d "$FLOW_JSON" | cat
  echo
}

# These flows classify by UE subnet per slice and map to queues 1/2/3
# Priority: higher number wins (URLLC highest)
echo "[3] Installing slice flows..."

# eMBB: 12.1.1.0/24 -> queue 1
push_flow '{
  "priority": 40000,
  "timeout": 0,
  "isPermanent": true,
  "deviceId": "'"$DEVICE_ID"'",
  "treatment": { "instructions": [ { "type": "SET_QUEUE", "queueId": 1 }, { "type": "OUTPUT", "port": "NORMAL" } ] },
  "selector": { "criteria": [ { "type": "ETH_TYPE", "ethType": "0x0800" }, { "type": "IPV4_SRC", "ip": "12.1.1.0/24" } ] }
}'

# URLLC: 12.1.2.0/24 -> queue 2 (higher priority)
push_flow '{
  "priority": 50000,
  "timeout": 0,
  "isPermanent": true,
  "deviceId": "'"$DEVICE_ID"'",
  "treatment": { "instructions": [ { "type": "SET_QUEUE", "queueId": 2 }, { "type": "OUTPUT", "port": "NORMAL" } ] },
  "selector": { "criteria": [ { "type": "ETH_TYPE", "ethType": "0x0800" }, { "type": "IPV4_SRC", "ip": "12.1.2.0/24" } ] }
}'

# mMTC: 12.1.3.0/24 -> queue 3
push_flow '{
  "priority": 30000,
  "timeout": 0,
  "isPermanent": true,
  "deviceId": "'"$DEVICE_ID"'",
  "treatment": { "instructions": [ { "type": "SET_QUEUE", "queueId": 3 }, { "type": "OUTPUT", "port": "NORMAL" } ] },
  "selector": { "criteria": [ { "type": "ETH_TYPE", "ethType": "0x0800" }, { "type": "IPV4_SRC", "ip": "12.1.3.0/24" } ] }
}'

echo "[DONE] Flows installed."
