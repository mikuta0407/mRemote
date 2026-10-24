# A Linux host for the SSH live tests: OpenSSH and tmux, public keys only,
# for the user "tester". The public key comes in at run time, in
# $AUTHORIZED_KEY: a bind mount would need the file under a directory the
# Docker VM shares, and the runners keep theirs in the temp directory.
# Tests that change tmux's state run here, never against the developer's
# own machine, whose tmux they could reach.
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-server tmux locales \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/# ja_JP.UTF-8/ja_JP.UTF-8/; s/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && useradd -m -s /bin/bash tester \
 && mkdir -p /run/sshd /home/tester/.ssh \
 && chown tester:tester /home/tester/.ssh && chmod 700 /home/tester/.ssh \
 && printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAcceptEnv LANG LC_*\n' > /etc/ssh/sshd_config.d/mremote.conf
ENV LANG=en_US.UTF-8
EXPOSE 22
CMD ["sh", "-c", "printf '%s\\n' \"$AUTHORIZED_KEY\" > /home/tester/.ssh/authorized_keys && chown tester:tester /home/tester/.ssh/authorized_keys && chmod 600 /home/tester/.ssh/authorized_keys && exec /usr/sbin/sshd -D -e"]
