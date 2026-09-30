# The backend as one image, for any Docker host (Render, a VPS, ...).
#
#   docker build -t medinv-backend backend
#   docker run -p 3000:3000 --env-file backend/.env medinv-backend
#
# On start it applies any new migrations, creates the admin, adds demo data
# when DEMO_DATA=true, then serves (scripts/start.sh). Pictures live in the
# database, so the container keeps nothing on disk and can be replaced at will.

FROM node:24-bookworm-slim AS build
WORKDIR /app
# Prisma's migration engine needs OpenSSL.
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
# Scripts print as they run, so a slow or failing install shows where.
RUN npm ci --foreground-scripts
COPY . .
RUN npx prisma generate && npm run build

FROM node:24-bookworm-slim
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*
ENV NODE_ENV=production
# The dev dependencies stay: `prisma migrate deploy` runs at every start, and
# `npm run db:seed` (ts-node) is how a new database gets its admin.
COPY --from=build /app/package.json /app/package-lock.json /app/tsconfig.json /app/prisma.config.ts ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/dist ./dist
COPY --from=build /app/scripts ./scripts
EXPOSE 3000
# Migrations, the admin, optional demo data, then serve: see scripts/start.sh.
# Hosts that set PORT (Render does) are honoured by the app's config.
CMD ["sh", "scripts/start.sh"]
