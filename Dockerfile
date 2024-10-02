#syntax=docker/dockerfile:1

ARG UPSTREAM_TAG=latest
FROM ghcr.io/actions/actions-runner:$UPSTREAM_TAG

# ARGS need to be redecleared after FROM statement
ARG NODE_VERSION=20.x
ARG TARGETARCH

# Add Common Tools
RUN <<EOR
set -o errexit
sudo apt-get update -y
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:git-core/ppa
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  curl \
  dumb-init \
  git \
  git-lfs \
  gpg \
  openssl \
  jq \
  unzip \
  zip

sudo rm -rf /var/lib/apt/lists/*

sudo mkdir /_work && sudo chown runner:runner /_work
EOR

# Add Azure CLI
RUN <<EOR
set -o errexit
curl -fsLS https://packages.microsoft.com/keys/microsoft.asc |
  gpg --dearmor |
  sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null
sudo chmod a+r /etc/apt/keyrings/microsoft.gpg

echo "deb [arch=$TARGETARCH signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" |
  sudo tee /etc/apt/sources.list.d/azure-cli.list

sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  azure-cli

sudo rm -rf /var/lib/apt/lists/*
EOR

# Add node.js
RUN <<EOR
set -o errexit
curl -fsLS https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
  gpg --dearmor |
  sudo tee /etc/apt/keyrings/nodesource.gpg > /dev/null
sudo chmod a+r /etc/apt/keyrings/nodesource.gpg

echo "deb [arch=$TARGETARCH signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_VERSION nodistro main" |
  sudo tee /etc/apt/sources.list.d/nodesource.list

sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  nodejs

sudo rm -rf /var/lib/apt/lists/*
EOR

COPY --chmod=0755 ./entrypoint.sh .
ENTRYPOINT ["./entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
