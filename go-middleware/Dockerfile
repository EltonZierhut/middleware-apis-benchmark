FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/middleware .

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/middleware /middleware
EXPOSE 8080
ENTRYPOINT ["/middleware"]
