FROM node:20-bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
COPY public ./public

ENV MIRROR_HOST=0.0.0.0
ENV MIRROR_TCP_PORT=27183
ENV MIRROR_HTTP_PORT=8080

EXPOSE 27183/tcp 8080/tcp
CMD ["node", "server.js"]
