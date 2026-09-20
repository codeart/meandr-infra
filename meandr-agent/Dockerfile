# meandr-agent: one image, two jobs on a hosted node (hosted_nodes.md §7).
#   - daemon service (default entrypoint): /agent monitors the INSTANCE —
#     host cpu/mem/disk/net + per-container via docker.sock — and POSTs
#     to BE (contracts/hosted_agent_report.md)
#   - init container: entryPoint override copies /meandr (the public CLI)
#     to the shared volume the workload runs it from
#
# Build context is a dist/ dir holding BOTH repos' release binaries:
#   (cd ~/Workspace/meandr-cli   && make release ENDPOINT=tun.meandr.live)
#   (cd ~/Workspace/meandr-agent && make release)
#   ctx=$(mktemp -d) && cp ~/Workspace/meandr-cli/dist/meandr-linux-* \
#     ~/Workspace/meandr-agent/dist/meandr-agent-linux-* $ctx/
#   docker build -f meandr-agent/Dockerfile --platform linux/arm64 \
#     --build-arg ARCH=arm64 -t <registry>/meandr-agent $ctx
FROM busybox:1.37-musl
ARG ARCH=arm64
COPY meandr-linux-${ARCH} /meandr
COPY meandr-agent-linux-${ARCH} /agent
ENTRYPOINT ["/agent"]
