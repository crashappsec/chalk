  ARG BASE=two

  FROM alpine as one

  FROM ubuntu:24.04 as two
  COPY --from=docker /usr/local/bin/docker /docker
  COPY --from=busybox:latest /bin/busybox /busybox

  FROM busybox@sha256:9ae97d36d26566ff84e8893c64a6dc4fe8ca6d1144bf5b87b2b85a32def253c7 as three

  FROM nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe as four

  FROM one as five
  COPY --from=nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe /usr/sbin/nginx /nginx
  COPY --from=one /bin/sh /sh

  FROM $BASE
  COPY --from=four /usr/sbin/nginx /nginx
