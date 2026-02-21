FROM alpine:3.20

RUN apk add --no-cache openssh-server && \
    adduser -D -s /sbin/nologin sftpuser && \
    # Keep password auth disabled in sshd, but ensure the account is not shadow-locked
    # so public-key authentication is allowed.
    passwd -d sftpuser

RUN echo "Subsystem sftp internal-sftp" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "AllowTcpForwarding no" >> /etc/ssh/sshd_config && \
    echo "X11Forwarding no" >> /etc/ssh/sshd_config && \
    echo "AllowAgentForwarding no" >> /etc/ssh/sshd_config && \
    echo "PermitTunnel no" >> /etc/ssh/sshd_config && \
    echo "Match User sftpuser" >> /etc/ssh/sshd_config && \
    echo "  ForceCommand internal-sftp" >> /etc/ssh/sshd_config && \
    echo "  ChrootDirectory %h" >> /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
