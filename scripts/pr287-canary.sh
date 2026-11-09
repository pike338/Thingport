#!/usr/bin/env bash
# Temporary Thingport PR #287 frontend canary. Run INSIDE LXC CT171.
# Usage: bash thingport-pr287-canary.sh {start|status|stop}
set -euo pipefail
ACTION="${1:-start}"
NAME="thingport-pr287-frontend"
IP="192.168.1.71"
PORT="18081"
SHA="8bd9c288651eb1d683eae93b5a6d0837a657c2b3"
IMG="thingport-pr287-frontend:${SHA:0:12}"
WORKDIR="/opt/thingport-pr287-canary"

case "$ACTION" in
  status)
    docker ps -a --filter "name=^/${NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    exit 0
    ;;
  stop)
    if docker inspect "$NAME" >/dev/null 2>&1; then docker rm -f "$NAME"; fi
    echo "Canary stopped. Production containers unchanged."
    exit 0
    ;;
  start) ;;
  *) echo 'Usage: start|status|stop' >&2; exit 2 ;;
esac

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root inside CT171" >&2; exit 1; }
for x in git docker curl df awk; do command -v "$x" >/dev/null || { echo "Missing $x" >&2; exit 1; }; done
[[ "$(docker inspect -f '{{.State.Running}}' thingport-backend)" == true ]] || { echo "Backend not running" >&2; exit 1; }
[[ "$(docker inspect -f '{{.State.Running}}' thingport-frontend)" == true ]] || { echo "Frontend not running" >&2; exit 1; }
if docker inspect "$NAME" >/dev/null 2>&1; then
  echo "Canary already exists; use status or stop" >&2; exit 1
fi
NET="$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' thingport-backend | grep '^thingport_default$' || true)"
[[ "$NET" == thingport_default ]] || { echo "Expected Docker network thingport_default not found; aborting" >&2; exit 1; }
ROOT="$(docker info -f '{{.DockerRootDir}}')"
FREE="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
MEM="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
(( FREE >= 6*1024*1024 )) || { echo "Less than 6 GiB free in Docker root; aborting" >&2; exit 1; }
(( MEM >= 2*1024*1024 )) || { echo "Less than 2 GiB available memory; aborting" >&2; exit 1; }
# In LXC, MemAvailable may reflect host RAM rather than the cgroup limit.
if [[ -r /sys/fs/cgroup/memory.max && -r /sys/fs/cgroup/memory.current ]]; then
  LIMIT="$(cat /sys/fs/cgroup/memory.max)"
  USED="$(cat /sys/fs/cgroup/memory.current)"
  if [[ "$LIMIT" != max ]] && (( LIMIT - USED < 2*1024*1024*1024 )); then
    echo "Less than 2 GiB free under the LXC memory limit; aborting" >&2
    exit 1
  fi
fi
[[ ! -e "$WORKDIR/source" ]] || { echo "Existing source directory; refusing overwrite" >&2; exit 1; }
mkdir -p "$WORKDIR"

git clone --depth 1 --single-branch --branch fix/creality-print-bridge-handoff \
  https://github.com/pike338/Thingport.git "$WORKDIR/source"
[[ "$(git -C "$WORKDIR/source" rev-parse HEAD)" == "$SHA" ]] || { echo "Fork branch moved; refusing build" >&2; exit 1; }
docker build --pull --build-arg "GIT_SHA=$SHA" -t "$IMG" \
  -f "$WORKDIR/source/frontend/Dockerfile" "$WORKDIR/source/frontend"

docker run -d --name "$NAME" --restart=no \
  --security-opt no-new-privileges:true --memory 256m --cpus 0.5 \
  --network "$NET" -p "${IP}:${PORT}:80" "$IMG" >/dev/null

for _ in $(seq 1 20); do
  if curl -fsS --max-time 5 -o /dev/null "http://${IP}:${PORT}/" &&
     docker exec "$NAME" wget -q -O /dev/null http://backend:8000/api/health; then
    echo "Canary ready: http://${IP}:${PORT}/"
    echo "Production stays at http://${IP}:8080/"
    exit 0
  fi
  sleep 2
done
echo "Canary not healthy; inspect: docker logs $NAME" >&2
exit 1
