# hosted-cli: the init container hosted nodes copy the CLI from
# (hosted_nodes.md §7). busybox because the copy step needs a cp; the
# workload container then runs /shared/meandr as its entryPoint.
#
# Build context is the PUBLIC cli's dist/ — nothing internal leaves this
# repo, nothing internal enters that one:
#   (cd ~/Workspace/meandr-cli && make release ENDPOINT=tun.meandr.live)
#   docker build -f hosted-cli/Dockerfile --platform linux/arm64 \
#     --build-arg ARCH=arm64 -t <registry>/hosted-cli ~/Workspace/meandr-cli/dist
FROM busybox:1.37-musl
ARG ARCH=arm64
COPY meandr-linux-${ARCH} /meandr
ENTRYPOINT ["/bin/sh", "-c", "cp /meandr /shared/meandr && chmod 755 /shared/meandr"]
