# syntax=docker/dockerfile:1
FROM alpine:3.21

# hadolint ignore=DL3018
RUN apk add --no-cache bash curl jq tini \
    && adduser -D -u 10001 monitor \
    && mkdir -p /var/lib/ollama-node-monitor /metrics \
    && chown monitor:monitor /var/lib/ollama-node-monitor /metrics

COPY --chmod=755 bin/ollama-node-monitor /usr/local/bin/ollama-node-monitor

USER monitor
ENV STATE_DIR=/var/lib/ollama-node-monitor \
    OLLAMA_URL=http://ollama:11434
VOLUME ["/var/lib/ollama-node-monitor"]

ENTRYPOINT ["/sbin/tini", "--", "ollama-node-monitor"]
