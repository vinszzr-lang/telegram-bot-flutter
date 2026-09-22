#!/bin/sh
set -e
export ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
npm install --omit=dev
exec node index.js
