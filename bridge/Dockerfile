FROM python:3.12-slim

RUN useradd --create-home --uid 10001 kestrel \
    && mkdir -p /sidecar/config /sidecar/state /sidecar/storage /sidecar/.reticulum \
    && chown -R kestrel /sidecar
WORKDIR /app
COPY pyproject.toml ./
COPY kestrel_bridge ./kestrel_bridge
RUN pip install --no-cache-dir .

USER kestrel
ENV KESTREL_CONFIG=/sidecar/config/bridge.toml \
    PYTHONUNBUFFERED=1
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["python", "-m", "kestrel_bridge", "--healthcheck"]
CMD ["python", "-m", "kestrel_bridge"]
