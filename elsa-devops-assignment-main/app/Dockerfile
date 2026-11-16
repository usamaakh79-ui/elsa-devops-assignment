# syntax=docker/dockerfile:1
# ---- build stage: resolve Python deps into an isolated prefix ----
FROM python:3.13-alpine AS build
WORKDIR /src
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ---- runtime stage: no pip cache, no build tooling, non-root ----
FROM python:3.13-alpine
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080
# Pick up fixed OS packages and drop pip (not needed at runtime, frequent CVE source).
RUN apk upgrade --no-cache && python -m pip uninstall -y pip
COPY --from=build /install /usr/local
WORKDIR /app
COPY main.py .
# Numeric UID so Kubernetes `runAsNonRoot` can verify it without /etc/passwd lookups.
RUN addgroup -S -g 10001 app && adduser -S -D -H -u 10001 -G app app
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["python", "main.py"]
