FROM golang:1.18 AS builder
WORKDIR /opt
COPY go.mod go.sum main.go /opt/
RUN go get && CGO_ENABLED=0 go build -a -installsuffix cgo

FROM alpine:3.15
WORKDIR /opt
COPY *.mmdb /opt/
COPY --from=builder /opt/ipenrich /bin/ipenrich
RUN chmod +x /bin/ipenrich \
    && addgroup -S nopriv && adduser -S nopriv -G nopriv
USER nopriv
EXPOSE 8000
CMD ["ipenrich"]
