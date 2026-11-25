FROM python:3.12-slim

RUN useradd --create-home --uid 10001 kestrel
WORKDIR /app
COPY pyproject.toml ./
COPY kestrel_bridge ./kestrel_bridge
RUN pip install --no-cache-dir .

USER kestrel
CMD ["python", "-m", "kestrel_bridge"]
