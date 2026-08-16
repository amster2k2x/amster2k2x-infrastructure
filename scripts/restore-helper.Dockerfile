# Small helper image: postgres client + AWS CLI, just enough to pull a
# golden dump from S3 and restore it before the real app container starts.
# Build once, push to GHCR, reference via var.restore_helper_image.
#
#   docker build -t ghcr.io/amster2k2x/staging-restore-helper:latest -f restore-helper.Dockerfile .
#   docker push ghcr.io/amster2k2x/staging-restore-helper:latest

FROM postgres:16-alpine

RUN apk add --no-cache aws-cli

COPY restore.sh /restore.sh
RUN chmod +x /restore.sh

ENTRYPOINT ["/restore.sh"]
