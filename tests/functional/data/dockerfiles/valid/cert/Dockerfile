FROM alpine
COPY cert.pem /etc/cert.pem
CMD set -x && cat ${CERT:-/etc/cert.pem} && sleep 5
