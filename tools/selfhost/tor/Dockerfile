FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends tor qrencode \
 && rm -rf /var/lib/apt/lists/*
COPY torrc /etc/tor/torrc.in
COPY pair start /usr/local/bin/
RUN chmod 755 /usr/local/bin/pair /usr/local/bin/start && mkdir -p /var/lib/tor && chown debian-tor:debian-tor /var/lib/tor
USER debian-tor
CMD ["/usr/local/bin/start"]
