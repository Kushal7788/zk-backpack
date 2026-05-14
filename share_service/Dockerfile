# syntax=docker/dockerfile:1
FROM node:20-alpine

WORKDIR /app

# Curl is used by Fly's TCP health-check fallback; tini for clean
# signal handling.
RUN apk add --no-cache tini

# share_service has zero npm dependencies, so no `npm install` step is
# required. Copy package.json for engines metadata and src/ for code.
COPY package.json ./
COPY src ./src

# /data is the mount point of the persistent volume declared in
# fly.toml. The runtime DATA_DIR env var points here.
RUN mkdir -p /data
ENV DATA_DIR=/data
ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/server.js"]
