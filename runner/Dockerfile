# The image every self-hosted job runs inside, and the reason a job stops seeing the host's
# ports: a container has its own network namespace, so a dev server or a test database bound
# in here is bound in here only. The runner machines are Macs, where `container:` in a workflow
# is rejected (actions/runner, ContainerOperationProvider.cs:49), so the runner goes in a
# container instead of creating one.
#
# Playwright's own image is the base because `playwright install` fetches browsers and not the
# system libraries they link against. Its tag is the org's baseline; a repository pinning a
# different @playwright/test installs its own browsers into /ms-playwright at job time, which
# the chown below permits and which costs that job a download.
FROM mcr.microsoft.com/playwright:v1.62.1-noble

# https://github.com/actions/runner/releases - the digest is published in that release's notes.
ARG RUNNER_VERSION=2.337.0
ARG RUNNER_SHA256=9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393

USER root

# `libicu74` is the runner binary's own hard dependency, `zstd` is what actions/cache compresses
# with, and `docker-ce-cli` is a client only: a job using testcontainers drives the host daemon
# through the socket the launcher mounts, and no daemon starts in here.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl git jq sudo unzip xz-utils zstd libicu74 \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
  && chmod a+r /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
       > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker-ce-cli \
  && rm -rf /var/lib/apt/lists/*

# `run.sh` refuses to start as root, and passwordless sudo is what lets the entrypoint join the
# group owning the mounted docker socket, whose gid is the host's and not knowable at build time.
#
# 1002 because the base image already seeds `ubuntu` at 1000 and `pwuser` at 1001. The id is
# pinned rather than allocated: the named volumes outlive the image, and carry its ownership.
RUN useradd --create-home --shell /bin/bash --uid 1002 runner \
  && echo 'runner ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/runner \
  && chmod 0440 /etc/sudoers.d/runner \
  && chown -R runner:runner /ms-playwright

USER runner
WORKDIR /home/runner/actions-runner

RUN curl -fsSL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" \
  && echo "${RUNNER_SHA256}  runner.tar.gz" | sha256sum -c - \
  && tar xzf runner.tar.gz \
  && rm runner.tar.gz

# The base image's browsers, so a repository on the same Playwright finds them already there
# instead of fetching a second copy into the home directory every job.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
ENTRYPOINT ["/home/runner/entrypoint.sh"]
