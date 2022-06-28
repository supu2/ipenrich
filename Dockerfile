FROM alpine:3.15

RUN addgroup -S nopriv && adduser -S nopriv -G nopriv
USER nopriv
CMD ["sleep", "60"]
