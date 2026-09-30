#!/bin/sh
# How the backend container starts. Every step is safe to repeat, so a host
# can restart it at will (free hosts do, often).
set -e

# 1. Bring the database schema up to date.
npx prisma migrate deploy

# 2. Settings, and the admin from SEED_ADMIN_USERNAME / SEED_ADMIN_PASSWORD.
#    An existing admin is never touched, so a changed password survives.
npm run db:seed

# 3. With DEMO_DATA=true, demo data for an EMPTY catalogue. Once there is a
#    catalogue it says so and changes nothing; that is not a reason to stop.
if [ "$DEMO_DATA" = "true" ]; then
  node dist/demo/seed-demo.js || echo "Demo data skipped."
fi

# 4. Serve.
exec node dist/main
