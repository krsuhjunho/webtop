# syntax=docker/dockerfile:1
#
# Personal webtop: Ubuntu 26.04 (resolute) KDE Plasma on linuxserver's Selkies
# base. Arch-specific base tags are selected with build-args (see the workflow).
#   amd64: ghcr.io/linuxserver/baseimage-selkies:ubunturesolute
#          ghcr.io/linuxserver/selkies-layers:amd64-ubunturesolute-kwin
#   arm64: ghcr.io/linuxserver/baseimage-selkies:arm64v8-ubunturesolute
#          ghcr.io/linuxserver/selkies-layers:arm64v8-ubunturesolute-kwin

ARG BASEIMAGE=ghcr.io/linuxserver/baseimage-selkies:ubunturesolute
ARG KWIN_LAYER=ghcr.io/linuxserver/selkies-layers:amd64-ubunturesolute-kwin

FROM ${KWIN_LAYER} AS kwin
FROM ${BASEIMAGE}

ARG TARGETARCH
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="webtop" \
      org.opencontainers.image.description="Ubuntu 26.04 KDE webtop (Selkies) with Korean and Japanese input" \
      org.opencontainers.image.source="https://github.com/krsuhjunho/webtop" \
      org.opencontainers.image.licenses="GPL-3.0-only"

ENV TITLE="Webtop" \
    PIXELFLUX_WAYLAND=true \
    TZ=Asia/Tokyo \
    LANG=ko_KR.UTF-8 \
    LANGUAGE=ko_KR:ko:ja_JP:ja:en \
    LC_ALL=ko_KR.UTF-8 \
    GTK_IM_MODULE=fcitx \
    QT_IM_MODULE=fcitx \
    QT_IM_MODULES=wayland;fcitx \
    XMODIFIERS=@im=fcitx \
    SDL_IM_MODULE=fcitx \
    INPUT_METHOD=fcitx \
    GLFW_IM_MODULE=ibus \
    XKB_DEFAULT_RULES=evdev \
    XKB_DEFAULT_MODEL=pc105 \
    XKB_DEFAULT_LAYOUT=kr \
    SHELL=/usr/bin/zsh \
    START_DOCKER=false \
    SELKIES_ENABLE_CLIPBOARD=true \
    SELKIES_CLIPBOARD_SEAMLESS=true \
    SELKIES_ENABLE_BINARY_CLIPBOARD=true \
    BROWSER=/usr/local/bin/wrapped-brave

ARG NERD_FONTS_VERSION=3.5.1

RUN \
  echo "**** locales and timezone ****" && \
  apt-get update && \
  apt-get install -y --no-install-recommends locales tzdata ca-certificates curl gnupg && \
  sed -i 's/^# \(ko_KR.UTF-8 UTF-8\)/\1/' /etc/locale.gen && \
  sed -i 's/^# \(ja_JP.UTF-8 UTF-8\)/\1/' /etc/locale.gen && \
  sed -i 's/^# \(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen && \
  locale-gen && \
  ln -snf /usr/share/zoneinfo/Asia/Tokyo /etc/localtime && \
  printf 'Asia/Tokyo\n' > /etc/timezone && \
  echo "**** package sources ****" && \
  install -d -m 0755 /etc/apt/keyrings /usr/share/keyrings && \
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
  chmod a+r /etc/apt/keyrings/docker.asc && \
  . /etc/os-release && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list && \
  curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    -o /usr/share/keyrings/brave-browser-archive-keyring.gpg && \
  echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=$(dpkg --print-architecture)] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-release.list && \
  apt-get update && \
  echo "**** desktop, input, tools ****" && \
  apt-get install -y --no-install-recommends \
    bat \
    brave-browser \
    btop \
    curl \
    dolphin \
    eza \
    fd-find \
    fcitx5 \
    fcitx5-config-qt \
    fcitx5-frontend-all \
    fcitx5-hangul \
    fcitx5-mozc \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    fonts-noto-core \
    fonts-noto-mono \
    fzf \
    gedit \
    git \
    gwenview \
    htop \
    im-config \
    jq \
    kde-config-gtk-style \
    language-pack-kde-ja \
    language-pack-kde-ko \
    kdialog \
    kfind \
    khotkeys \
    kio-extras \
    knewstuff-dialog \
    konsole \
    ksystemstats \
    kubuntu-settings-desktop \
    kwin-addons \
    kwin-style-aurorae \
    kwin-x11 \
    kwrite \
    language-pack-ja \
    language-pack-ko \
    libcap2-bin \
    ncdu \
    neovim \
    p7zip-full \
    papirus-icon-theme \
    pipewire \
    plasma-desktop \
    plasma-workspace \
    qml-module-qt-labs-platform \
    qt6-style-kvantum \
    ripgrep \
    rsync \
    sudo \
    systemsettings \
    tmux \
    tree \
    unzip \
    vim \
    vlc \
    vlc-plugin-qt \
    wget \
    wireplumber \
    wl-clipboard \
    xdg-desktop-portal \
    xdg-desktop-portal-kde \
    yq \
    zoxide \
    zsh \
    docker-ce-cli \
    docker-compose-plugin && \
  if [ -x /usr/bin/batcat ] && [ ! -e /usr/local/bin/bat ]; then ln -s /usr/bin/batcat /usr/local/bin/bat; fi && \
  if [ -x /usr/bin/fdfind ] && [ ! -e /usr/local/bin/fd ]; then ln -s /usr/bin/fdfind /usr/local/bin/fd; fi && \
  if [ -x /usr/libexec/docker/cli-plugins/docker-compose ]; then ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose; fi && \
  echo "**** fonts ****" && \
  mkdir -p /usr/local/share/fonts/hack-nerd /usr/local/share/fonts/d2coding /tmp/hack /tmp/d2 && \
  curl -fsSL -o /tmp/Hack.zip "https://github.com/ryanoasis/nerd-fonts/releases/download/v${NERD_FONTS_VERSION}/Hack.zip" && \
  unzip -q /tmp/Hack.zip -d /tmp/hack && \
  find /tmp/hack -type f \( \
      -name 'HackNerdFontMono-Regular.ttf' -o \
      -name 'HackNerdFontMono-Bold.ttf' -o \
      -name 'HackNerdFontMono-Italic.ttf' -o \
      -name 'HackNerdFontMono-BoldItalic.ttf' \
    \) -exec cp {} /usr/local/share/fonts/hack-nerd/ \; && \
  curl -fsSL -o /tmp/D2Coding.zip "https://github.com/naver/d2codingfont/releases/download/VER1.3.2/D2Coding-Ver1.3.2-20180524.zip" && \
  unzip -q /tmp/D2Coding.zip -d /tmp/d2 && \
  find /tmp/d2 -type f -name '*.ttf' -exec cp {} /usr/local/share/fonts/d2coding/ \; && \
  fc-cache -f && \
  echo "**** oh-my-zsh ****" && \
  git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git /usr/share/oh-my-zsh && \
  rm -rf /usr/share/oh-my-zsh/.git && \
  echo "**** kde / clipboard tweaks ****" && \
  if [ -f /usr/share/applications/brave-browser.desktop ]; then \
    sed -i \
      -e 's#Exec=/usr/bin/brave-browser-stable#Exec=/usr/local/bin/wrapped-brave#g' \
      -e 's#Exec=brave-browser-stable#Exec=/usr/local/bin/wrapped-brave#g' \
      -e 's#Exec=/usr/bin/brave-browser#Exec=/usr/local/bin/wrapped-brave#g' \
      -e 's#Exec=brave-browser#Exec=/usr/local/bin/wrapped-brave#g' \
      /usr/share/applications/brave-browser.desktop; \
  fi && \
  if [ -x /usr/bin/kwin_wayland ]; then setcap -r /usr/bin/kwin_wayland || true; fi && \
  rm -f /usr/share/dbus-1/system-services/org.freedesktop.UDisks2.service && \
  echo "**** cleanup ****" && \
  apt-get autoremove -y && \
  apt-get clean && \
  rm -rf \
    /config/.cache \
    /config/.launchpadlib \
    /tmp/* \
    /var/lib/apt/lists/* \
    /var/tmp/*

COPY --from=kwin / /
COPY root/ /

RUN chmod 755 \
    /custom-cont-init.d/10-webtop \
    /defaults/startwm.sh \
    /defaults/startwm_wayland.sh \
    /usr/local/bin/wrapped-brave \
    /usr/local/bin/webtop-tune \
    /usr/local/bin/webtop-mime \
    /usr/local/bin/webtop-patch-vlc \
    /kwin-xwayland.py \
    /etc/xdg/plasma-workspace/env/im.sh \
    /etc/profile.d/im.sh \
 && cp /etc/xdg/mimeapps.list /usr/share/applications/mimeapps.list \
 && python3 /usr/local/bin/webtop-patch-vlc \
 && python3 - <<'PY'
from pathlib import Path
path = Path("/usr/share/applications/brave-browser.desktop")
if path.exists():
    lines = path.read_text().splitlines()
    section = ""
    out = []
    for line in lines:
        if line.startswith("["):
            section = line.strip()
        if section == "[Desktop Action new-window]" and line.startswith("Exec=") and "--new-window" not in line:
            line = line.rstrip() + " --new-window"
        out.append(line)
    path.write_text("\n".join(out) + "\n")
PY

EXPOSE 3000 3001
VOLUME /config
