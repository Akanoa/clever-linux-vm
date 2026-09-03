# The Docker daemon a vm-agent box borrows.
#
# Deployed as a Clever Cloud "docker" application with
# CC_MOUNT_DOCKER_SOCKET=true, so this container talks to the daemon of the
# instance it runs on and the containers it starts are its siblings, not
# children. Its only job is to run an sshd that hands one fleet VM two
# things: a forwarded /var/run/docker.sock, and the port forwards that let
# the VM reach whatever Testcontainers just started.
#
# Two ports, both platform defaults - do not move them. 8080 is what the
# health check probes, and an instance that never answers there is killed
# and restarted forever. 4040 is where a TCP redirection delivers traffic.
FROM alpine:3.21

# socat for the health responder: alpine's busybox is built without the
# httpd applet, and a health endpoint that never binds hangs the whole
# deployment - the platform waits on port 8080 and says nothing.
RUN apk add --no-cache bash openssh-server docker-cli curl jq socat

COPY dockerd/entrypoint.sh /usr/local/bin/dockerd-entrypoint
RUN chmod +x /usr/local/bin/dockerd-entrypoint

EXPOSE 8080 4040
CMD ["/usr/local/bin/dockerd-entrypoint"]
