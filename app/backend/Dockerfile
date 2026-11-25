# One image for api, collector and migrate (different commands): one thing to scan, sign and patch.
FROM python:3.13-slim@sha256:7249d5587b78209a006dc4a3b5340678f84ea729239193aa559962cd8c1fce50 AS build
WORKDIR /src
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.13-slim@sha256:7249d5587b78209a006dc4a3b5340678f84ea729239193aa559962cd8c1fce50
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 LOCATIONS_FILE=/app/locations.json
# Patch OS packages, and drop pip/setuptools from the runtime image: the app never installs anything at
# runtime, and pip's bundled libraries (urllib3, msgpack) were the source of the image's Python CVEs.
RUN apt-get update && apt-get upgrade -y --no-install-recommends && rm -rf /var/lib/apt/lists/* \
    && python -m pip uninstall -y pip setuptools wheel
COPY --from=build /install /usr/local
WORKDIR /app
COPY weather ./weather
COPY locations.json .
# RDS CA bundle for sslmode=verify-full on AWS. Checksum-pinned: a changed/tampered file fails the build.
ADD --checksum=sha256:90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b \
    https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/rds-global-bundle.pem
# Fixed non-root UID so K8s runAsNonRoot can verify it.
USER 10001:10001
EXPOSE 8000
CMD ["uvicorn", "weather.api:app", "--host", "0.0.0.0", "--port", "8000", "--no-server-header"]
