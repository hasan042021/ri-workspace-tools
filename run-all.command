#!/bin/bash

set -euo pipefail

# EDIT these to your project dirs (no extra /Users in front)
DIRS=(
  # "$HOME/Code/ERP_Working/ERP"
  "$HOME/Code/ERP_Working/crm"
  "$HOME/Code/ERP_Working/RI-Auth"
  "$HOME/Code/ERP_Working/Sign-Server-ERP"
  "$HOME/Code/ERP_Working/tasks-manager-ri"
  "$HOME/Code/ERP_Working/ATS-Backend-Server"
  "$HOME/Code/ERP_Working/ATS-LLM-Server"
  "$HOME/Code/ERP_Working/RI-File-Explorer-Server"

)

CMD="npm run start:dev"
pids=()

cleanup() {
  echo ""
  echo "Stopping all child processes..."
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Wait for all children to exit
  for pid in "${pids[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup INT TERM

# Start each command and prefix its output with the folder name
for d in "${DIRS[@]}"; do
  name="$(basename "$d")"
  ( cd "$d" && $CMD ) | sed -e "s/^/[$name] /" &
  pids+=($!)
done

# Portable “wait for any to exit” (bash 3.2 compatible)
while :; do
  for pid in "${pids[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      cleanup
      exit
    fi
  done
  sleep 1
done
