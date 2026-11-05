FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/upstream .

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/upstream /upstream
EXPOSE 9000
ENTRYPOINT ["/upstream"]
