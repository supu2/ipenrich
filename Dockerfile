FROM golang AS builder
WORKDIR /opt
COPY go.mod go.sum main.go /opt/ 
RUN CGO_ENABLED=0 GOOS=linux go get && go build -installsuffix cgo  


FROM alpine:3.15
WORKDIR /opt
COPY *.mmdb /opt/
COPY --from=builder /opt/ipenrich /bin/ipenrich
RUN chmod +x /bin/ipenrich \
    && addgroup -S nopriv && adduser -S nopriv -G nopriv
USER nopriv
EXPOSE 8000
CMD ["ipenrich"]
