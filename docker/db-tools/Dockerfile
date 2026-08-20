FROM postgres:16-alpine

# aws-cli: S3 and Secrets Manager access
# jq: parse Secrets Manager JSON response
# curl: lightweight connectivity checks during debugging
RUN apk add --no-cache \
        aws-cli \
        jq \
        curl \
    && rm -rf /var/cache/apk/*

RUN mkdir /scripts

COPY scripts/backup.sh  /scripts/backup.sh
COPY scripts/restore.sh /scripts/restore.sh
RUN chmod +x /scripts/backup.sh /scripts/restore.sh

# Never runs automatically — GitHub Actions always passes --overrides with
# either /scripts/backup.sh or /scripts/restore.sh. Exits 1 if forgotten.
CMD ["/bin/sh", "-c", \
     "echo 'ERROR: No command override. Pass /scripts/backup.sh or /scripts/restore.sh via --overrides.'; exit 1"]