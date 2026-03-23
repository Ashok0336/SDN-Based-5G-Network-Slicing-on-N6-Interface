#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP_DIR="$PWD/onos-slice-queue-app"
APP_JAR="$APP_DIR/target/onos-slice-queue-app-1.0.0.jar"
ONOS_CONT="${ONOS_CONT:-onos}"

echo "[onos-app] Building ONOS slice queue app with Maven Docker image..."
docker run --rm -v "$PWD/onos-slice-queue-app":/app -w /app maven:3.9-eclipse-temurin-11 mvn -q clean package

if [[ ! -f "$APP_JAR" ]]; then
  echo "[onos-app] ERROR: expected JAR not found: $APP_JAR" >&2
  exit 1
fi

echo "[onos-app] Copying app to ONOS container (${ONOS_CONT})..."
docker cp "$APP_JAR" "${ONOS_CONT}:/tmp/onos-slice-queue-app-1.0.0.jar"

echo "[onos-app] Installing app via Karaf onos-app..."
docker exec -it "$ONOS_CONT" /bin/bash -lc 'onos-app localhost install! /tmp/onos-slice-queue-app-1.0.0.jar'

echo "[onos-app] Installed. Verify flows with:"
echo 'docker exec ovs ovs-ofctl -O OpenFlow13 dump-flows br-n6 | egrep "set_queue|tp_dst=5201|tp_dst=5202|tp_dst=5203"'
