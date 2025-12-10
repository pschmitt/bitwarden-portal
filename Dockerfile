# syntax=docker/dockerfile:1
FROM node:25-alpine

ENV TZ="Europe/Berlin" \
    CRON_SCHEDULE="0 0 * * *"

WORKDIR /app

# hadolint ignore=DL3018
RUN apk --no-cache add \
    tzdata \
    ca-certificates

# hadolint ignore=DL3018
RUN apk --no-cache add \
    bash \
    coreutils \
    curl \
    findutils \
    jq \
    openssl \
    python3 \
    tar \
    util-linux

# hadolint ignore=DL3016
RUN npm install -g @bitwarden/cli

COPY bitwarden-portal.sh /app/backup.sh
COPY bw.py /app/bw.py
COPY certs/ /usr/local/share/ca-certificates/
COPY certs/ /usr/share/ca-certificates/

RUN update-ca-certificates

RUN chmod +x /app/backup.sh /app/bw.py

# hadolint ignore=DL3002
CMD ["sh", "-c", "echo \"$CRON_SCHEDULE /app/backup.sh > /proc/1/fd/1 2>&1\" > /etc/crontabs/root && crond -f -L /dev/stdout"]
