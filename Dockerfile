FROM alpine:3.20

ARG SFTP_UID=1000
ARG SFTP_GID=1000

RUN apk add --no-cache openssh-server nss_wrapper && \
    addgroup -g "${SFTP_GID}" -S sftpgroup && \
    adduser -D -u "${SFTP_UID}" -G sftpgroup -h /home/sftpuser -s /bin/sh sftpuser && \
    # Keep password auth disabled in sshd config, but ensure account is not shadow-locked
    # so public-key authentication is allowed.
    passwd -d sftpuser && \
    mkdir -p /home/sftpuser/.config /home/sftpuser/.ssh /home/sftpuser/data /keys /host_keys && \
    chown sftpuser:sftpgroup /home/sftpuser/.config /home/sftpuser/.ssh /home/sftpuser/data && \
    chown root:root /home/sftpuser && \
    chmod 755 /home/sftpuser /home/sftpuser/data && \
    chmod 700 /home/sftpuser/.ssh && \
    chmod 1777 /keys /host_keys

COPY sshd_config.template /etc/ssh/sshd_config.template

COPY entrypoint.sh /entrypoint.sh
RUN chmod 644 /etc/ssh/sshd_config.template && \
    chmod +x /entrypoint.sh

ENV PUID=${SFTP_UID} \
    PGID=${SFTP_GID} \
    SFTP_PATHS=/data \
    SSH_KEY_DIR=/keys \
    HOST_KEY_DIR=/host_keys \
    SFTP_CHROOT=true

EXPOSE 2022

USER sftpuser

ENTRYPOINT ["/entrypoint.sh"]
