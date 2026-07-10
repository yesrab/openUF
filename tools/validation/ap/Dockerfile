# Disposable "AP" container for validating openUF against a real UniFi
# controller (see PROTOCOL-VALIDATION.md). Not a target-hardware image --
# this is a plain Alpine box with just enough on it for:
#   - `lua inform.lua` to run the inform loop
#   - sshd to be reachable, so the controller's real adopt flow (SSH in,
#     run `syswrapper.sh set-adopt <url> <key>`) completes exactly like it
#     would against genuine OpenWrt hardware
#
# UCI-backed calls (ucihelper.lua) will error on this non-OpenWrt box --
# that's fine, the goal is capturing the controller's pushed JSON via
# debug_dump_file (openuf/conf.lua) before UCI apply, not exercising UCI
# itself. There is no lua-openssl package in Alpine's repos, so crypto.lua
# transparently falls back to shelling out to the openssl CLI.
FROM alpine:3.20

RUN apk add --no-cache \
        lua5.1 lua5.1-cjson lua5.1-socket lua5.1-bitop \
        openssh openssl iw \
    && ln -sf /usr/bin/lua5.1 /usr/bin/lua

# Root SSH login with a fixed password -- fine here, this is a disposable
# validation container on an isolated docker network, not real hardware.
RUN ssh-keygen -A \
    && echo 'root:openuf' | chpasswd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY openuf/ /opt/openuf/
RUN ln -sf /opt/openuf/hook/syswrapper.sh /usr/bin/syswrapper.sh \
    && chmod +x /usr/bin/syswrapper.sh /opt/openuf/hook/syswrapper.sh \
    && mkdir -p /etc/openuf /var/log

WORKDIR /opt/openuf
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]
