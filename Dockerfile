FROM alpine:3.20

RUN apk add --no-cache openssh-server && \
    adduser -D -h /home/sftpuser -s /sbin/nologin sftpuser && \
    # Keep password auth disabled in sshd, but ensure the account is not shadow-locked
    # so public-key authentication is allowed.
    passwd -d sftpuser && \
    mkdir -p /run/sshd /etc/ssh/sftpuser_keys && \
    # Never bake host keys into images.
    rm -f /etc/ssh/ssh_host_*

COPY sshd_config /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
RUN chmod 600 /etc/ssh/sshd_config && \
    chmod +x /entrypoint.sh

ENV SFTP_PORT=22 \
    SFTP_PATHS=/data \
    SSH_KEY_DIR=/home/sftpuser/.ssh \
    HOST_KEY_DIR=/home/sftpuser/.host_keys

EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
