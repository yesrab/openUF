# Disposable "AP" container for validating openUF against a real UniFi
# controller (see PROTOCOL-VALIDATION.md). Not a target-hardware image --
# this is a plain Alpine box with just enough on it for:
#   - `lua inform.lua` to run the inform loop
#   - sshd to be reachable, so the controller's real adopt flow (SSH in,
#     run `syswrapper.sh set-adopt <url> <key>`) completes exactly like it
#     would against genuine OpenWrt hardware
#
# UCI-backed calls (ucihelper.lua) would error on this non-OpenWrt box with
# no real `uci` binding -- fixed by installing uci-mock.lua below (a fake
# `uci` module, validation-only, not part of openUF) so ucihelper.lua's
# require("uci") fallback resolves to an in-memory backend instead of
# failing. This unblocks capturing the SHAPE of controller-pushed WiFi/VLAN/
# TX-power config (openUF's own real product code is untouched); actually
# exercising real wireless hardware application is still out of scope here.
#
# AES-GCM is MANDATORY, not optional. This controller (10.4.57) puts
# use_aes_gcm=true in every mgmt_cfg and will NOT provision a device until
# it has received a genuine GCM-encrypted inform: the inform handler
# (com.ubnt.service.devmgr.l.MiVjHefaf) loops "mgmt config update before
# provision" -- re-sending mgmt_cfg with a fresh random cfgversion every
# cycle -- until the device's x_aes_gcm flag flips true, which only happens
# when the InformServlet decrypts a GCM (not CBC) packet. Without a GCM
# backend, openUF's crypto.lua silently downgrades to CBC (the openssl(1)
# CLI cannot do GCM -- `enc` refuses AEAD ciphers), x_aes_gcm never flips,
# and the device is stuck in "Adopting" forever. There is no prebuilt
# lua-openssl apk, so build the zhaozg/lua-openssl rock (crypto.lua's
# preferred backend) from source. See PROTOCOL-VALIDATION.md
# "AES-GCM is mandatory for adoption".
FROM alpine:3.20

RUN apk add --no-cache \
        lua5.1 lua5.1-cjson lua5.1-socket lua5.1-bitop \
        openssh openssl iw \
    && ln -sf /usr/bin/lua5.1 /usr/bin/lua \
    && apk add --no-cache --virtual .build-deps \
        luarocks5.1 lua5.1-dev openssl-dev gcc musl-dev make \
    && luarocks-5.1 install openssl \
    && apk del .build-deps

# Root SSH login with a fixed password -- fine here, this is a disposable
# validation container on an isolated docker network, not real hardware.
#
# HostKeyAlgorithms/PubkeyAcceptedAlgorithms: the real controller's SSH
# client (sshj) only offers the legacy "ssh-rsa" (SHA-1) signature scheme
# when adopting -- matching genuine UBNT firmware's old SSH stack. OpenSSH
# has disabled ssh-rsa from its default algorithm list since 8.8 (this
# image ships 9.7), which fails adoption's SSH handshake with "Unable to
# reach a settlement of HostKeyAlgorithms" even though an RSA host key
# exists. Re-enabling it here is what makes real SSH-based adoption work.
#
# The controller's SSH adopt flow doesn't use the admin-configured "Device SSH
# Authentication" credentials for a device announcing itself as unadopted
# (IsDefault=1 in the L2 discovery packet, see announce.lua) -- it tries the
# real Ubiquiti factory-default account, "ubnt"/"ubnt", exactly like it would
# against genuine out-of-box hardware. Add that account (UID 0, so it's
# root-equivalent like real UBNT firmware's ubnt account) so SSH adopt
# actually succeeds here.
RUN ssh-keygen -A \
    && echo 'root:openuf' | chpasswd \
    && echo 'ubnt:x:0:0:ubnt:/root:/bin/sh' >> /etc/passwd \
    && echo 'ubnt:ubnt' | chpasswd \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && printf '\nHostKeyAlgorithms +ssh-rsa\nPubkeyAcceptedAlgorithms +ssh-rsa\n' >> /etc/ssh/sshd_config

COPY openuf/ /opt/openuf/
COPY tools/validation/ap/uci-mock.lua /usr/local/share/lua/5.1/uci.lua
RUN ln -sf /opt/openuf/hook/syswrapper.sh /usr/bin/syswrapper.sh \
    && chmod +x /usr/bin/syswrapper.sh /opt/openuf/hook/syswrapper.sh \
    && mkdir -p /etc/openuf /var/log \
    && sed -i 's/debug_dump_file = nil/debug_dump_file = "\/var\/log\/openuf-informs.log"/' \
        /opt/openuf/conf.lua \
    && sed -i 's/lan_cpueth\t= "eth1"/lan_cpueth\t= "eth0"/' \
        /opt/openuf/modelmap/generic-dualband-ap.lua

# generic-dualband-ap.lua assumes real hardware's switch topology (eth0=WAN,
# eth1=LAN via VLANs) -- this single-NIC container only has eth0. Without
# this override, announce.get_mac/get_ip (used by inform.lua's
# _populate_net_info) silently fail to find "eth1", leaving st.mac/st.ip
# unset -- informs then report MAC 00:00:00:00:00:00 and IP 0.0.0.0, which
# the controller cannot adopt (it has no address to SSH the device at).

WORKDIR /opt/openuf
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]
