# DESIGNED FOR BUILDING ON AMD64 ONLY
#####################################
# Requires binfm_misc registration
# https://github.com/multiarch/qemu-user-static#binfmt_misc-register
ARG DOTNET_VERSION=6.0

FROM node:lts-alpine as web-builder
ARG JELLYFIN_WEB_VERSION=master
RUN apk add curl git zlib zlib-dev autoconf g++ make libpng-dev gifsicle alpine-sdk automake libtool make gcc musl-dev nasm python3 \
 && curl -L https://github.com/jellyfin/jellyfin-web/archive/${JELLYFIN_WEB_VERSION}.tar.gz | tar zxf - \
 && cd jellyfin-web-* \
 && npm ci --no-audit --unsafe-perm \
 && mv dist /dist

FROM debian:stable-slim as app

# https://askubuntu.com/questions/972516/debian-frontend-environment-variable
ARG DEBIAN_FRONTEND="noninteractive"
# http://stackoverflow.com/questions/48162574/ddg#49462622
ARG APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=DontWarn
# https://github.com/NVIDIA/nvidia-docker/wiki/Installation-(Native-GPU-Support)
ENV NVIDIA_DRIVER_CAPABILITIES="compute,video,utility"

# https://github.com/intel/compute-runtime/releases
ARG GMMLIB_VERSION=21.2.1
ARG IGC_VERSION=1.0.8517
ARG NEO_VERSION=21.35.20826
ARG LEVEL_ZERO_VERSION=1.2.20826



# Install dependencies:
# mesa-va-drivers: needed for AMD VAAPI. Mesa >= 20.1 is required for HEVC transcoding.
# curl: healthcheck
RUN apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y ca-certificates gnupg wget apt-transport-https curl git\
 && wget -O - https://repo.jellyfin.org/jellyfin_team.gpg.key | apt-key add - \
 && echo "deb [arch=$( dpkg --print-architecture )] https://repo.jellyfin.org/$( awk -F'=' '/^ID=/{ print $NF }' /etc/os-release ) $( awk -F'=' '/^VERSION_CODENAME=/{ print $NF }' /etc/os-release ) main" | tee /etc/apt/sources.list.d/jellyfin.list \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y \
   mesa-va-drivers \
   jellyfin-ffmpeg \
   openssl \
   locales \
# Intel VAAPI Tone mapping dependencies:
# Prefer NEO to Beignet since the latter one doesn't support Comet Lake or newer for now.
# Do not use the intel-opencl-icd package from repo since they will not build with RELEASE_WITH_REGKEYS enabled.
 && mkdir intel-compute-runtime \
 && cd intel-compute-runtime \
 && wget https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-gmmlib_${GMMLIB_VERSION}_amd64.deb \
 && wget https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC_VERSION}/intel-igc-core_${IGC_VERSION}_amd64.deb \
 && wget https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC_VERSION}/intel-igc-opencl_${IGC_VERSION}_amd64.deb \
 && wget https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-opencl_${NEO_VERSION}_amd64.deb \
 && wget https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-ocloc_${NEO_VERSION}_amd64.deb \
 && wget https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-level-zero-gpu_${LEVEL_ZERO_VERSION}_amd64.deb \
 && dpkg -i *.deb \
 && cd .. \
 && rm -rf intel-compute-runtime \
 # && ./build_ffmpeg.sh \
 && apt-get remove gnupg wget apt-transport-https git -y \
 && apt-get clean autoclean -y \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /cache /config /media \
 && chmod 777 /cache /config /media \
 && sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
 

# ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
ENV LC_ALL en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en

FROM debian:bullseye as CustomFFMPEG
RUN apt-get update && apt-get install -y git \
&& git clone https://github.com/kainlan/jellyfin-ffmpeg
WORKDIR /jellyfin-ffmpeg/

# Docker build arguments
ARG SOURCE_DIR=/ffmpeg
ARG ARTIFACT_DIR=/dist
# Docker run environment
ENV DEB_BUILD_OPTIONS=noddebs
ENV DEBIAN_FRONTEND=noninteractive
ENV ARCH=amd64
ENV GCC_VER=10
ENV SOURCE_DIR=/ffmpeg
ENV ARTIFACT_DIR=/dist
ENV TARGET_DIR=/usr/lib/jellyfin-ffmpeg
ENV DPKG_INSTALL_LIST=${SOURCE_DIR}/debian/jellyfin-ffmpeg5.install
ENV PATH=${TARGET_DIR}/bin:${PATH}
ENV PKG_CONFIG_PATH=${TARGET_DIR}/lib/pkgconfig:${PKG_CONFIG_PATH}
ENV LD_LIBRARY_PATH=${TARGET_DIR}/lib:${TARGET_DIR}/lib/mfx:${TARGET_DIR}/lib/xorg:${LD_LIBRARY_PATH}
ENV LDFLAGS="-Wl,-rpath=${TARGET_DIR}/lib -L${TARGET_DIR}/lib"
ENV CXXFLAGS="-I${TARGET_DIR}/include $CXXFLAGS"
ENV CPPFLAGS="-I${TARGET_DIR}/include $CPPFLAGS"
ENV CFLAGS="-I${TARGET_DIR}/include $CFLAGS"

# Prepare Debian build environment
RUN apt-get update \
 && yes | apt-get install -y apt-transport-https curl ninja-build debhelper gnupg wget devscripts mmv equivs git nasm pkg-config subversion dh-autoreconf libpciaccess-dev libwayland-dev libx11-dev libx11-xcb-dev libxcb-dri2-0-dev libxcb-dri3-dev libxcb-present-dev libxcb-shm0-dev libxcb-sync-dev libxshmfence-dev libxext-dev libxfixes-dev libxcb1-dev libxrandr-dev libzstd-dev libelf-dev libudev-dev python3-pip python3-mako zip unzip tar flex bison

# Install meson and cmake
RUN pip3 install meson cmake
# Avoids timeouts when using git and disable the detachedHead advice
RUN git config --global http.postbuffer 524288000 && git config --global advice.detachedHead false
# Link to docker-build script
RUN ln -sf ${SOURCE_DIR}/docker-build.sh /docker-build.sh

VOLUME ${ARTIFACT_DIR}/

COPY . ${SOURCE_DIR}/

RUN ./docker-build.sh


FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} as builder
WORKDIR /repo
COPY . .
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
# because of changes in docker and systemd we need to not build in parallel at the moment
# see https://success.docker.com/article/how-to-reserve-resource-temporarily-unavailable-errors-due-to-tasksmax-setting
RUN dotnet publish Jellyfin.Server --disable-parallel --configuration Release --output="/jellyfin" --self-contained --runtime linux-x64 "-p:DebugSymbols=false;DebugType=none"


FROM app

ENV HEALTHCHECK_URL=http://localhost:8096/health

COPY --from=builder /jellyfin /jellyfin
COPY --from=web-builder /dist /jellyfin/jellyfin-web
COPY --from=CustomFFMPEG /ffmpeg /usr/lib/jellyfin-ffmpeg/ffmpeg

EXPOSE 8096
VOLUME /cache /config /media
ENTRYPOINT ["./jellyfin/jellyfin", \
    "--datadir", "/config", \
    "--cachedir", "/cache", \
    "--ffmpeg", "/usr/lib/jellyfin-ffmpeg/ffmpeg"]

HEALTHCHECK --interval=30s --timeout=30s --start-period=10s --retries=3 \
     CMD curl -Lk "${HEALTHCHECK_URL}" || exit 1
