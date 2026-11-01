FROM debian:trixie-slim AS ytdlp-builder

ARG TARGETPLATFORM

RUN apt-get update && \
    apt-get install -y \
        curl

RUN set -euo pipefail; \
    case "${TARGETPLATFORM}" in \
        "linux/amd64") YT_DLP_DOWNLOAD="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux"         ;; \
        "linux/arm64") YT_DLP_DOWNLOAD="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux_aarch64" ;; \
        *) echo "Unknown platform" && exit 1 ;; \
    esac; \
    curl -L ${YT_DLP_DOWNLOAD} -o /usr/local/bin/yt-dlp && \
    chmod a+rx /usr/local/bin/yt-dlp



FROM debian:trixie-slim AS sqlean-builder

RUN apt-get update && \
    apt-get install -y \
        curl \
        unzip

WORKDIR /
# Fetch the SQLean SQLite extensions into priv/ (pinned version, not in git) so
# `mix release` bundles them into the OTP release.
COPY tooling/fetch-sqlean.sh tooling/fetch-sqlean.sh
RUN tooling/fetch-sqlean.sh



FROM debian:trixie-slim AS ffmpeg-builder

ARG TARGETPLATFORM
RUN apt-get update && \
    apt-get install -y \
        curl \
        unzip \
        xz-utils

# ffmpeg is pinned for issue #347 (illegal instruction on some CPUs).
# Newer builds must be smoke-tested manually before bumping. FFMPEG_BUILD is paired with
# FFMPEG_RELEASE — both come from the same yt-dlp/FFmpeg-Builds release page.
ENV FFMPEG_RELEASE="autobuild-2026-06-30-16-38" \
    FFMPEG_BUILD="N-125365-g9a01c1cb6a"

WORKDIR /
RUN set -euo pipefail; \
    FFMPEG_BASE_URL="https://github.com/yt-dlp/FFmpeg-Builds/releases/download/${FFMPEG_RELEASE}/ffmpeg-${FFMPEG_BUILD}"; \
    case "${TARGETPLATFORM}" in \
        "linux/amd64") FFMPEG_DOWNLOAD_URL="${FFMPEG_BASE_URL}-linux64-gpl.tar.xz"   ;; \
        "linux/arm64") FFMPEG_DOWNLOAD_URL="${FFMPEG_BASE_URL}-linuxarm64-gpl.tar.xz" ;; \
        *) echo "Unknown platform" && exit 1 ;; \
    esac; \
    echo "${FFMPEG_DOWNLOAD_URL}" && \
    curl -L ${FFMPEG_DOWNLOAD_URL} --output /tmp/ffmpeg.tar.xz && \
    tar -xf /tmp/ffmpeg.tar.xz --strip-components=2 --no-anchored -C /usr/bin/ ffmpeg ffprobe



FROM node:26-trixie-slim AS assets-deps-builder

COPY assets /assets
WORKDIR /assets
RUN npm install --global yarn && \
    yarn install



FROM elixir:1.20.5-otp-29 AS builder

WORKDIR /app
ENV MIX_ENV="prod"
ENV ERL_FLAGS="+JPperf true"
COPY mix.exs mix.lock ./

RUN mix deps.get --only ${MIX_ENV}

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY --from=sqlean-builder /priv/repo/extensions priv/repo/extensions
COPY lib lib
COPY --from=assets-deps-builder /assets assets
RUN mix assets.deploy && mix compile

COPY config/runtime.exs config/
COPY rel rel
RUN mix release



FROM debian:trixie-slim AS runner

RUN apt-get update && \
    apt-get install -y \
        libstdc++6 \
        openssl \
        libncurses6 \
        locales \
        apprise \
        quickjs
        
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/pinchflat /app
COPY --from=ytdlp-builder /usr/local/bin/yt-dlp /usr/local/bin/yt-dlp
COPY --from=ffmpeg-builder /usr/bin/ffmpeg /usr/bin/ffmpeg
COPY --from=ffmpeg-builder /usr/bin/ffprobe /usr/bin/ffprobe

ENV MIX_ENV=prod \
    RUN_CONTEXT=selfhosted \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    UMASK=022 \
    PORT=8945 \
    YT_DLP_OPTIONS="--js-runtimes quickjs"

RUN groupadd -g 1000 pinchflat && \
    useradd --no-create-home --shell /bin/sh -g pinchflat -u 1000 -g 1000 pinchflat
USER pinchflat

EXPOSE ${PORT} 
CMD [ "/app/bin/docker_start" ]
