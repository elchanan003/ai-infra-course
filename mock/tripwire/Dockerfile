# aiinfra-tripwire:1.0 -- dnsmasq (everything resolves to this container) + HTTP/TLS-SNI sink + hit counter API on :8000
FROM alpine:3.20
LABEL course=aiinfra
RUN apk add --no-cache dnsmasq python3
COPY tripwire.py /tripwire.py
EXPOSE 53/udp 53/tcp 80 443 8000
ENTRYPOINT ["python3", "-u", "/tripwire.py"]
