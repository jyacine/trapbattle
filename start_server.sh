#!/bin/bash
# start_server.sh — start the Godot HTTPS server fully detached from the SSH session
pkill -f "serve.py" 2>/dev/null
sleep 1
cd /home/labadmin/trapbattle-server
setsid nohup python3 serve.py export --port 8080 --no-browser \
  --cert cert.pem --key key.pem \
  > /home/labadmin/trapbattle-server/server.log 2>&1 < /dev/null &
echo $! > /home/labadmin/trapbattle-server/server.pid
echo "Started PID $(cat /home/labadmin/trapbattle-server/server.pid)"
