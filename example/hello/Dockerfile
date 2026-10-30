# Builds a static binary, then ships it alone on an empty base image.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hello main.go

FROM scratch
COPY --from=build /hello /hello
EXPOSE 80
ENTRYPOINT ["/hello"]
