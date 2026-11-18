# Postgres 16 with PL/Python and requests.
# Installed at build time, so container starts need no apt mirror.
FROM postgres:16

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      postgresql-plpython3-16 \
      python3-requests \
 && rm -rf /var/lib/apt/lists/*
