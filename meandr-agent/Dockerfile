# meandr-agent: one image, two jobs on a hosted node (hosted_nodes.md §7).
#   - init container: copies /meandr (the public CLI) to the shared volume
#     the workload runs it from
#   - daemon service: `agent` monitors the INSTANCE — host cpu/mem/disk,
#     the things no in-container CLI can own — and reports to BE
# The agent binary joins when the meandr-agent repo ships it; until then
# the image is the copy half only.
#
# Build context is the PUBLIC cli's dist/ — nothing internal leaves this
# repo, nothing internal enters that one:
#   (cd ~/Workspace/meandr-cli && make release ENDPOINT=tun.meandr.live)
#   docker build -f meandr-agent/Dockerfile --platform linux/arm64 \
#     --build-arg ARCH=arm64 -t <registry>/meandr-agent ~/Workspace/meandr-cli/dist
FROM busybox:1.37-musl
ARG ARCH=arm64
COPY meandr-linux-${ARCH} /meandr
ENTRYPOINT ["/bin/sh", "-c", "cp /meandr /shared/meandr && chmod 755 /shared/meandr"]
