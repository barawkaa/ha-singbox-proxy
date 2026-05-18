ARG BUILD_FROM=ghcr.io/home-assistant/aarch64-base:latest

FROM ghcr.io/sagernet/sing-box:latest AS singbox

FROM ${BUILD_FROM}

COPY --from=singbox /usr/local/bin/sing-box /usr/local/bin/sing-box

COPY run.sh /run.sh
COPY ui /etc/sing-box/ui
COPY servers.example.json /defaults/servers.json

RUN sed -i 's/\r$//' /run.sh && \
    chmod a+x /run.sh && \
    chmod a+x /usr/local/bin/sing-box

CMD ["/run.sh"]
