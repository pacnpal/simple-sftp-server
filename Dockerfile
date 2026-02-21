FROM alpine:3.20

ARG SFTP_UID=1000
ARG SFTP_GID=1000

RUN apk add --no-cache openssh-server shadow && \
    addgroup -g "${SFTP_GID}" -S sftpgroup && \
    adduser -D -u "${SFTP_UID}" -G sftpgroup -h /home/sftpuser -s /bin/sh sftpuser && \
    # Keep password auth disabled in sshd config, but ensure account is not shadow-locked
    # so public-key authentication is allowed.
    passwd -d sftpuser && \
    mkdir -p /home/sftpuser/.config /home/sftpuser/.ssh && \
    chown -R sftpuser:sftpgroup /home/sftpuser

COPY sshd_config.template /etc/ssh/sshd_config.template

COPY entrypoint.sh /entrypoint.sh
RUN chmod 644 /etc/ssh/sshd_config.template && \
    chmod +x /entrypoint.sh

ENV SFTP_PATHS=/data \
    SSH_KEY_DIR=/home/sftpuser/.ssh \
    HOST_KEY_DIR=/etc/ssh/host_keys

EXPOSE 2022

ENTRYPOINT ["/entrypoint.sh"]
