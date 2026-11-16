# syntax=docker/dockerfile:1
# Toolbox: every CLI the scripts need, plus the docker CLI + k3d so the
# toolbox itself can create the k3d cluster on the host's Docker daemon.
FROM alpine:3.22

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.31.5
ARG HELM_VERSION=v3.17.1
ARG TERRAFORM_VERSION=1.10.5
ARG K6_VERSION=v0.56.0
ARG K3D_VERSION=v5.8.3

RUN apk add --no-cache bash curl jq git docker-cli ca-certificates unzip flock coreutils

RUN set -eux; \
    ARCH="${TARGETARCH:-}"; \
    if [ -z "$ARCH" ]; then case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo "unsupported arch"; exit 1 ;; esac; fi; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" | tar -xz -C /tmp; \
    mv "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm; \
    curl -fsSLo /tmp/tf.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip"; \
    unzip -o /tmp/tf.zip terraform -d /usr/local/bin; \
    curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${ARCH}.tar.gz" | tar -xz -C /tmp; \
    mv "/tmp/k6-${K6_VERSION}-linux-${ARCH}/k6" /usr/local/bin/k6; \
    curl -fsSLo /usr/local/bin/k3d "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${ARCH}"; \
    chmod +x /usr/local/bin/*; \
    rm -rf /tmp/*; \
    kubectl version --client; helm version --short; terraform version; k6 version; k3d version

# Marker the scripts use to know they are already inside the toolbox.
RUN touch /.toolbox
WORKDIR /workspace
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# Runs as root deliberately: the toolbox's job is to drive the host Docker daemon
# (k3d creates the cluster nodes as sibling containers), and access to
# docker.sock is root-equivalent anyway - a non-root USER here would be cosmetic
# and would break on hosts where the socket's GID differs. Local dev tool only;
# never deployed. Reviewed exception to the Semgrep gate:
# nosemgrep: dockerfile.security.missing-user-entrypoint.missing-user-entrypoint
ENTRYPOINT ["/entrypoint.sh"]
