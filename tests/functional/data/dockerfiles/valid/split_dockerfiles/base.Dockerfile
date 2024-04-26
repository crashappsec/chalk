FROM alpine as base

RUN adduser -D testuser
RUN id
USER testuser
RUN id
