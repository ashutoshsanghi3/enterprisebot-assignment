# Stage 1: Builder
FROM python:3.11.9-slim AS builder

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Stage 2: Runner
FROM python:3.11.9-slim

# Copy virtual env from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app
COPY app.py .

# Create non-root user and set permissions
RUN useradd -m -r appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 8080
CMD ["python", "app.py"]