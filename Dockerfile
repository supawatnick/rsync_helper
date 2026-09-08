FROM alpine:3.19
RUN apk add --no-cache rsync coreutils tzdata \
 && mkdir -p /var/log/rsync
ENV TZ=Asia/Bangkok