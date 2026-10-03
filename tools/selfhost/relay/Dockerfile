FROM python:3.13-alpine@sha256:2dd78ad5cf13a0b68f5134dc49aa9950203a8cf4b7463431b9f3b398287c5059
RUN apk add --no-cache libqrencode-tools \
 && adduser -D -H -u 10001 relay \
 && mkdir -p /data && chown relay /data
COPY relay.py register /usr/local/bin/
RUN chmod 755 /usr/local/bin/relay.py /usr/local/bin/register
USER relay
CMD ["/usr/local/bin/relay.py"]
