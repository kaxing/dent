FROM alpine:edge AS build

RUN apk add --no-cache zig zstd-dev musl-dev bash coreutils python3

WORKDIR /src
COPY . .

RUN zig build -Doptimize=fast
RUN zig build test

FROM build AS integration
RUN bash test-coverage/integration.sh
RUN bash test-coverage/discovery.sh
RUN python3 test-coverage/logic.py
