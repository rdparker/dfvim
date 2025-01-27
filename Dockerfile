# --- BUILDENV ----------------------------------------------------------------
FROM fsharp as buildenv
RUN sed -i '{p;s/^deb /deb-src /}' /etc/apt/sources.list && \
    apt-get update && \
    apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get build-dep -y emacs25 && \
    apt-get install -y wget curl devscripts


# --- EMACS -------------------------------------------------------------------
FROM buildenv as build-emacs

RUN mkdir -p /opt && \
    EMACS_VERSION=26.2 && \
    EMACS_TARFILE=emacs-$EMACS_VERSION.tar.xz && \
    EMACS_SIG=emacs-$EMACS_VERSION.tar.xz.sig && \
    EMACS_BASE_URL=http://ftpmirror.gnu.org/gnu/emacs && \
    GNU_KEYRING_URL=https://ftp.gnu.org/gnu/gnu-keyring.gpg && \
    GPG_FINGERPRINT="D405 AA2C 862C 54F1 7EEE 6BE0 E8BC D786 6AFC F978" && \
    curl -SL $EMACS_BASE_URL/$EMACS_TARFILE --output $EMACS_TARFILE && \
    curl -SL $EMACS_BASE_URL/$EMACS_SIG --output $EMACS_SIG && \
    curl -SL $GNU_KEYRING_URL --output keyring.gpg && \
    gpg --import keyring.gpg && \
    gpg --output key --armor --export "$GPG_FINGERPRINT" && \
    rm -rf ~/.gnupg && \
    gpg --armor --import key && \
    gpg --verify $EMACS_SIG && \
    tar x -C /opt -f emacs-26.2.tar.xz && \
    mv /opt/emacs-26.2 /opt/emacs && \
    cd /opt/emacs && \
    ./autogen.sh && \
    mkdir /build && \
    cd /build && \
    /opt/emacs/configure --with-modules && \
    make -j 3 && \
    fakeroot bash -c "make install-arch-dep install-arch-indep prefix=/fakeroot"

# --- FSHARP .NET CORE 2.2.402 ------------------------------------------------
FROM fsharp as fsharp-netcore

ENV FrameworkPathOverride /usr/lib/mono/4.7.2-api/
ENV NUGET_XMLDOC_MODE skip
ENV DOTNET_CLI_TELEMETRY_OPTOUT 1
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get --no-install-recommends install -y \
    curl \
    libunwind8 \
    gettext \
    apt-transport-https \
    libc6 \
    libcurl3 \
    libgcc1 \
    libgssapi-krb5-2 \
    libicu57 \
    liblttng-ust0 \
    libssl1.0.2 \
    libstdc++6 \
    libunwind8 \
    libuuid1 \
    zlib1g && \
    rm -rf /var/lib/apt/lists/* && \
    DOTNET_SDK_VERSION=2.2.402 && \
    DOTNET_SDK_DOWNLOAD_URL=https://dotnetcli.blob.core.windows.net/dotnet/Sdk/$DOTNET_SDK_VERSION/dotnet-sdk-$DOTNET_SDK_VERSION-linux-x64.tar.gz && \
    DOTNET_SDK_DOWNLOAD_SHA=81937de0874ee837e3b42e36d1cf9e04bd9deff6ba60d0162ae7ca9336a78f733e624136d27f559728df3f681a72a669869bf91d02db47c5331398c0cfda9b44 && \
    curl -SL $DOTNET_SDK_DOWNLOAD_URL --output dotnet.tar.gz && \
    echo "$DOTNET_SDK_DOWNLOAD_SHA dotnet.tar.gz" | sha512sum -c - && \
    mkdir -p /usr/share/dotnet && \
    tar -zxf dotnet.tar.gz -C /usr/share/dotnet && \
    rm dotnet.tar.gz && \
    ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet && \
    mkdir warmup && \
    cd warmup && \
    dotnet new && \
    cd - && \
    rm -rf warmup /tmp/NuGetScratch
WORKDIR /root

# --- FSHARP 4.5 - .NET CORE 2.2.402 - EMACS 26.2  ----------------------------
from fsharp-netcore

ENV MONO_THREADS_PER_CPU 50
ENV LANG=en_US.utf-8

COPY --from=build-emacs /opt /opt/
COPY --from=build-emacs /fakeroot /usr/local/

# install some additional dev tools desired or required
RUN apt-get update -y && \
    apt-get --no-install-recommends install -yq apt-utils && \
    apt-get --no-install-recommends install -yq man less ctags wget curl git subversion ssh-client make unzip sudo rsync tmux && \
    apt-get			    install -yq ispell iamerican ibritish && \
    apt-get --no-install-recommends install -yq $(apt-cache depends emacs25 emacs25-bin emacs25-bin-common emacs25-common emacsen-common | awk '/Depends:/{print $2}' | grep -v emacs) && \
    apt-get clean

# set up dfemacs user with uid 1000 to (hopefully) match host uid
RUN useradd --shell /bin/bash -u 1000 -o -c "" -m -G sudo dfemacs && \
    echo 'alias tmux=TERM=xterm-256color\ tmux' >> /home/dfemacs/.bashrc && \
    echo 'set -g default-terminal "screen-256color"' >> /home/dfemacs/.tmux.conf

# configure Emacs with Spacemacs
COPY .spacemacs /home/dfemacs/
RUN mkdir /src && \
    ln -s /src /home/dfemacs/src && \
    git clone https://github.com/syl20bnr/spacemacs ~dfemacs/.emacs.d && \
    chown -R dfemacs /home/dfemacs /src && \
    TERM=xterm su dfemacs -c 'cd && script --force -qefc "emacs --batch -l ~/.emacs.d/init.el --eval \(save-buffers-kill-emacs\)" /home/dfemacs/typescript' && \
    rm /home/dfemacs/typescript && \
	mkdir -p /home/dfemacs/.emacs.d/private/local

# The projectile+ package adds autodetection of dotnet projects to
# projectile.  The projectile+ naming style is taken from Drew Adams
# dired+ and his other packages which enhance existing packages and
# load after them.  I will probably try to get this integrated
# into projectile.
COPY projectile+.el /home/dfemacs/.emacs.d/private/local/

# Install the latest supported OmniSharp server
RUN VERSION=$(curl https://raw.githubusercontent.com/OmniSharp/omnisharp-emacs/master/omnisharp-settings.el | \
	      grep omnisharp-expected-server-version | sed 's/.*"\(.*\)".*/\1/') && \
    mkdir -p /home/dfemacs/.emacs.d/.cache/omnisharp/server/v$VERSION && \
    wget -nv -O - https://github.com/OmniSharp/omnisharp-roslyn/releases/download/v$VERSION/omnisharp-linux-x64.tar.gz | \
	tar xzf - -C /home/dfemacs/.emacs.d/.cache/omnisharp/server/v$VERSION

USER dfemacs
WORKDIR /home/dfemacs
CMD ["/bin/bash"]
