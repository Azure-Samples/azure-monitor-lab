FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

RUN apt-get -o Acquire::Retries=5 update \
    && (apt-get -o Acquire::Retries=5 install -y --no-install-recommends ca-certificates curl gnupg lsb-release \
        || (rm -rf /var/lib/apt/lists/* \
            && apt-get -o Acquire::Retries=5 update \
            && apt-get -o Acquire::Retries=5 install -y --no-install-recommends ca-certificates curl gnupg lsb-release)) \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ jammy main" > /etc/apt/sources.list.d/azure-cli.list \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends azure-cli nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 runner

WORKDIR /runner
COPY --chown=runner:runner scripts/ ./scripts/
COPY --chown=runner:runner workloads/k8s/ ./workloads/k8s/
COPY --chown=runner:runner workloads/webapp/package.json workloads/webapp/package-lock.json ./workloads/webapp/
COPY --chown=runner:runner workloads/webapp/scripts/ ./workloads/webapp/scripts/
RUN cd /runner/workloads/webapp \
    && npm ci --ignore-scripts \
    && npx playwright install --with-deps chromium \
    && npm cache clean --force
RUN chown runner:runner /runner
USER runner
ENV LAB_RUNNER_MODE=ContainerAppsJob
ENV AZURE_EXTENSION_USE_DYNAMIC_INSTALL=no
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/runner/scripts/invoke-lab-operation.ps1"]