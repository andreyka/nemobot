FROM ghcr.io/browserless/chromium:latest

USER root
WORKDIR /opt/openclaw-browser

COPY cdp-proxy.js start.sh ./
RUN chmod 0755 /opt/openclaw-browser/start.sh /opt/openclaw-browser/cdp-proxy.js

USER blessuser
EXPOSE 9223

ENTRYPOINT ["/opt/openclaw-browser/start.sh"]
