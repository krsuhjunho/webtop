# Webtop

브라우저로 쓰는 데스크톱입니다. 기본 이미지는 Ubuntu 26.04 KDE Plasma 를 [linuxserver Selkies](https://github.com/linuxserver/docker-baseimage-selkies) `baseimage-selkies:ubunturesolute` 위에 올렸고, 한국어와 일본어 입력, zsh, 자주 쓰는 CLI를 넣었습니다. 세션 스크립트는 [linuxserver/docker-webtop](https://github.com/linuxserver/docker-webtop) `ubuntu-kde` 브랜치를 바탕으로 했고, 저장소 라이선스는 GPL-3.0-only 입니다.

GPU 가 없는 소형 ARM VM 에서는 KasmVNC + XFCE 변형이 더 가볍습니다. 두 변형은 같은 저장소에 따로 올라가고, mTLS Nginx 앞단은 둘 다 포트 3000 으로 붙습니다.

이미지는 `ghcr.io/krsuhjunho/webtop` 에 `linux/amd64` 와 `linux/arm64` 로 올라갑니다. Selkies 태그는 `latest`, UTC 기준 `yymmdd`, `sha-<커밋>` 입니다. Kasm 태그는 `kasm`, `kasm-yymmdd`, `kasm-sha-<커밋>` 입니다. `main` 푸시, 수동 실행, 매주 월요일 빌드가 두 베이스 이미지 갱신을 따라갑니다.

## 변형

| | Selkies (기본) | Kasm |
| --- | --- | --- |
| 태그 | `latest` | `kasm` |
| 베이스 | `baseimage-selkies:ubunturesolute` | `baseimage-kasmvnc:ubuntunoble` (Ubuntu 24.04, 빌드 때 `apt upgrade`) |
| 데스크톱 | KDE Plasma, Wayland | XFCE, X11. KDE 세션은 넣지 않습니다 |
| 웹 포트 | 3000 HTTP / 3001 HTTPS | 같음. 화면 소켓은 `/websockify`, 소리는 `/audio/socket.io`. 컨테이너 Nginx 가 3000 으로 모읍니다 |
| 성능 프로파일 | `low-power`, `balanced`, `quality` | 없음. `./webtop.sh profile` 은 Selkies 전용이라고 알리고 환경 변수는 바꾸지 않습니다 |

공통으로 들어가는 것은 시간대 `Asia/Tokyo`, 로케일 `ko_KR.UTF-8`, fcitx5(한글 + mozc) 자동 시작, 클립보드, Brave(GPU 래스터 끔), VLC, Gwenview, zsh 와 같은 CLI 입니다. Gwenview 는 이미지 보기만 쓰고 Plasma 데스크톱은 끌어오지 않습니다.

서버에서 바꾸는 방법:

```bash
./webtop.sh variant kasm      # deploy/.env 에 WEBTOP_VARIANT=kasm, IMAGE_TAG=kasm
./webtop.sh variant selkies   # WEBTOP_VARIANT=selkies, IMAGE_TAG=latest
```

실행 중인 `webtop` 컨테이너가 있으면 그 컨테이너만 새 태그로 다시 만듭니다. `/config` 볼륨은 그대로입니다. `update`, `check-update`, `auto-update` 는 `IMAGE_TAG` 를 봅니다. 비어 있거나 `latest`/`kasm` 이면 변형의 이동 태그를 따라가고, `kasm-251111` 처럼 고정한 태그는 그대로 둡니다.

`deploy/.env` 를 직접 고칠 때는 두 값을 같이 맞춥니다.

```bash
WEBTOP_VARIANT=kasm
IMAGE_TAG=kasm
```

직접 실행할 때는 이미지만 바꾸면 됩니다.

```bash
docker run -d \
  --name webtop \
  --shm-size=2g \
  --security-opt seccomp:unconfined \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Asia/Tokyo \
  -p 3001:3001 \
  -v webtop-config:/config \
  ghcr.io/krsuhjunho/webtop:kasm
```

Kasm 웹 클라이언트는 접속할 때마다 옆 메뉴의 스피커를 눌러야 소리가 났습니다. 브라우저는 사용자 입력이 있기 전에는 `AudioContext` 를 막으므로, 페이지에 넣은 `webtop-audio.js` 가 첫 클릭이나 키 입력에서 스피커 버튼과 같은 `audio()` 를 한 번만 호출합니다. 데스크톱은 iframe 이라 그 입력은 부모 페이지로 올라가지 않습니다. VNC 페이지에 넣은 같은 스크립트가 그 순간에 `parent.webtopEnableAudio()` 를 호출합니다. 스피커 버튼을 직접 누르면 훅은 끼어들지 않아 버튼이 두 번 토글되지 않습니다. 한 번 켠 뒤에는 버튼으로 끌 수 있습니다.

`/config` 를 두 변형이 같이 씁니다. Selkies 가 만들어 둔 fcitx 자동 시작이 KWin 자리 표시자면 Kasm 시작 때 XFCE 용으로 바꿉니다. 그 외 fcitx 설정은 유지합니다. KDE 설정 파일은 XFCE 가 읽지 않습니다.

아래 기능 설명은 Selkies KDE 기준입니다. Kasm 은 Wayland, KWin, Selkies 인코더 변수를 쓰지 않습니다.

## 기능

- Ubuntu 26.04, KDE Plasma 6, Selkies (Wayland, 포트 3001 HTTPS / 3000 HTTP)
- 로케일 `ko_KR.UTF-8`, `ja_JP.UTF-8`, `en_US.UTF-8`. 기본 언어는 한국어
- 기본 시간대 `Asia/Tokyo` (시스템 시계와 데스크톱 시계)
- fcitx5 + 한글(hangul) + 일본어(mozc), 세션마다 자동 시작
- 글꼴: Noto Sans / Noto CJK, D2Coding, Hack Nerd Font Mono, Noto Color Emoji
- 기본 브라우저 Brave. 동영상은 VLC, 이미지는 Gwenview
- 기본 셸 zsh + oh-my-zsh (`abc` 사용자), zoxide 연결
- bat, eza, fd, jq, yq, ripgrep, fzf, git, curl, wget, htop, btop, tmux, vim, neovim, unzip, p7zip, rsync, tree, ncdu
- GTK 편집기 gedit (입력기 확인용)
- Docker CLI 와 Compose 플러그인 (호스트 소켓을 마운트해서 사용. 컨테이너 안의 dockerd 는 켜지 않음)
- `abc` 비밀번호 없는 sudo
- 파일 업로드/다운로드와 소리 출력은 Selkies 가 제공합니다
- 선택 사항: mTLS Nginx, 클라이언트 인증서 CRL, 한국/일본 GeoIP 제한

KDE 패키지는 linuxserver `ubuntu-kde` 와 같게 맞추되, 용량을 줄이려고 `synaptic`, `plasma-discover`, `kubuntu-wallpapers` 는 넣지 않았습니다. 클립보드는 배포판 `wl-clipboard` 를 씁니다.

## 바로 실행

설정과 홈은 `/config` 입니다. 이름이 있는 볼륨이나 바인드 마운트로 유지하세요. 공유 메모리는 2GB 이상이어야 합니다.

```bash
docker run -d \
  --name webtop \
  --shm-size=2g \
  --security-opt seccomp:unconfined \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Asia/Tokyo \
  -e LANG=ko_KR.UTF-8 \
  -e LC_ALL=ko_KR.UTF-8 \
  -e TITLE=Webtop \
  -p 3001:3001 \
  -v webtop-config:/config \
  ghcr.io/krsuhjunho/webtop:latest
```

브라우저에서 `https://호스트:3001` 을 엽니다. 컨테이너가 만든 인증서는 자체 서명이라 경고가 납니다. 이 포트는 인증이 없습니다. 인터넷에 그대로 열지 마세요. 아래 mTLS 구성을 쓰면 3000/3001 은 호스트에 공개하지 않습니다.

호스트 도커를 컨테이너 안에서 쓰려면 `-v /var/run/docker.sock:/var/run/docker.sock` 을 추가합니다.

## 환경 변수

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `PUID` / `PGID` | `1000` | `/config` 와 `abc` 계정의 uid/gid. `0` 이면 세션이 root 가 되고 VLC 가 뜨지 않습니다 |
| `TZ` | `Asia/Tokyo` | 시스템 시간대. 데스크톱 시계도 이 값을 따릅니다 |
| `LANG` | `ko_KR.UTF-8` | 세션 언어. `ja_JP.UTF-8` 또는 `en_US.UTF-8` |
| `LC_ALL` | `ko_KR.UTF-8` | `LANG` 보다 우선합니다. 언어를 바꿀 때 둘 다 지정하세요 |
| `LANGUAGE` | `ko_KR:ko:ja_JP:ja:en` | 번역 폴백 |
| `TITLE` | `Webtop` | 브라우저 탭 제목 |
| `CUSTOM_USER` / `PASSWORD` | 없음 | 설정하면 Selkies HTTP 기본 인증. mTLS 와 별개입니다 |
| `XKB_DEFAULT_LAYOUT` | `kr` | 키보드 레이아웃. 한글/한자 키가 있는 QWERTY |
| `GTK_IM_MODULE` | `fcitx` | GTK 입력기 |
| `QT_IM_MODULE` | `fcitx` | Qt 입력기 (Konsole, KWrite) |
| `XMODIFIERS` | `@im=fcitx` | XWayland 입력기 |
| `SELKIES_ENABLE_CLIPBOARD` | `true` | `true`, `in`, `out`, `false` |
| `SELKIES_CLIPBOARD_SEAMLESS` | `true` | 복사할 때마다 양방향 동기화 |
| `WEBTOP_PROFILE` | `low-power` | `low-power`, `balanced`, `quality` |
| `SELKIES_ENCODER` | `jpeg` | `jpeg` 또는 `h264enc` (소프트웨어 x264) |
| `SELKIES_FRAMERATE` | `30` | 스트림 프레임 |
| `SELKIES_AUDIO_ENABLED` | `true` | `false` 면 소리 캡처와 PipeWire 를 끕니다 |
| `WEBTOP_BRAVE_LOW_CPU` | `1` | Brave GPU 래스터를 끕니다 |

그 밖에 `SUBFOLDER`, `CUSTOM_PORT` 같은 Selkies/linuxserver 변수도 그대로 동작합니다.

## 포트

| 포트 | 용도 |
| --- | --- |
| 3000 | 컨테이너 안 HTTP. 리버스 프록시는 이 포트로 붙습니다 |
| 3001 | 컨테이너 안 HTTPS (자체 서명). 직접 접속할 때만 사용 |

mTLS compose 에서는 webtop 의 3000/3001 을 호스트에 바인딩하지 않습니다. Nginx 가 `HTTPS_PORT`(기본 443)를 열고, `HTTP_PORT` 가 비어 있지 않을 때만 HTTP 리다이렉트를 엽니다.

## 한국어 / 일본어 입력

세션 키보드 레이아웃은 `kr` 입니다. 영문은 QWERTY 이고 한/영 키와 한자 키가 있습니다. 일본어는 로마자(mozc)라 같은 자판으로 입력합니다.

fcitx5 는 KWin 가상 키보드로 매 세션 시작 시 올라옵니다. 기본은 영문(입력기 꺼짐)이고, 처음 켜면 한글입니다.

| 키 | 동작 |
| --- | --- |
| 한/영 (`Hangul`) | 입력기 켜기/끄기. 꺼진 상태에서 누르면 한글 |
| `Ctrl+Space` | 한/영 과 동일 |
| `Ctrl+Shift` 또는 `Alt+Shift` | 영어 자판 → 한글 → mozc 순환 |
| 반각/전각 (`Zenkaku_Hankaku`) | 입력기 켜기/끄기 (일본어 키보드) |

호스트(맥, 윈도, 리눅스) 입력기가 조합을 가로채면 컨테이너 fcitx 전편집이 나오지 않습니다. **호스트 입력기는 영문으로 두고**, 데스크톱 안에서 위 키로 바꾸세요. 호스트가 이미 조합한 한글/일본어는 Selkies 가 완성된 문자열로 넣습니다. 이때 전편집은 호스트 쪽에 보이고, KWin 은 가상 키보드 프로토콜이 없어 클립보드 붙여넣기(`Shift+Insert`)로 글자를 전달한 뒤 이전 클립보드를 복구합니다. 두 입력기를 동시에 켜면 글자가 두 번 들어가거나 클립보드가 깜빡일 수 있습니다.

폰 소프트 키보드의 IME 도 호스트 조합 경로입니다. 전편집은 기기에 뜨고, 확정된 글자만 세션에 들어갑니다.

GTK(gedit)는 `GTK_IM_MODULE=fcitx` 와 `gtk-im-module=fcitx` 를 씁니다. Qt(Konsole, KWrite)는 `QT_IM_MODULE=fcitx`. Brave 는 Wayland + text-input v1 (`--enable-wayland-ime --wayland-text-input-version=1`) 으로 실행합니다. 컨테이너에서는 Chromium 샌드박스가 막히므로 Brave 런처가 `--no-sandbox` 를 붙입니다. `--shm-size=2g` 와 `seccomp:unconfined` 는 그대로 필요합니다. 기본 프로그램은 웹은 Brave, 이미지는 Gwenview, 영상/소리는 VLC 입니다.

Selkies 는 캡처용 컴포지터와 KWin 이 중첩이라, 자판에 없는 키심볼은 글자 입력으로 넘깁니다. `XKB_DEFAULT_LAYOUT=kr` 이라 한/영 키심볼은 실제 키로 전달됩니다. 맥의 한/영 키는 `Lang1` 으로 들어와 전달되지 않을 수 있습니다. 그때는 `Ctrl+Space` 또는 `Ctrl+Shift` 를 쓰세요. 맥이 `Ctrl+Space` 를 입력 소스 전환에 쓰고 있으면 그 단축키를 끄거나, 세션 안에서는 `Ctrl+Shift` 만 사용하세요.

리눅스 호스트의 Chromium + fcitx 가 Selkies 페이지에서 키를 삼키던 문제는 Selkies 쪽에서 수정되어 현재 베이스 이미지에 포함되어 있습니다. 호스트 입력기로 칠 때만 해당합니다.

입력기 설정을 처음 상태로 되돌리려면 컨테이너를 멈추고 볼륨 안의 `.config/fcitx5` 를 지웁니다. 세션 로그는 `/config/logs/session.log` 입니다.

### 입력 문제

- 한글이 안 되면 호스트 입력기가 영문인지 확인한 뒤, 세션에서 `Ctrl+Space` 를 누릅니다.
- 후보 창이 깜빡이면 Wayland text-input 과 fcitx 모듈이 겹친 경우입니다. `/config/.config/plasma-workspace/env/im-local.sh` 를 만들어 `unset GTK_IM_MODULE QT_IM_MODULE` 한 다음 컨테이너를 재시작합니다. KWin 가상 키보드는 유지됩니다. XWayland 앱은 모듈이 없으면 입력이 약해질 수 있습니다.
- `fcitx5-remote` 가 실패하면 세션이 아직 안 뜬 것입니다. `fcitx5-remote -n` 이 `hangul` 또는 `mozc` 를 돌려주면 전환은 된 것입니다.
- 진단: 터미널에서 `fcitx5-diagnose`.

## 클립보드

기본값이 양방향이고(`SELKIES_ENABLE_CLIPBOARD=true`, `SELKIES_CLIPBOARD_SEAMLESS=true`) 한글/일본어 텍스트를 포함합니다. 동기화는 영상과 같은 WebSocket 으로 가므로 Nginx 가 WebSocket 을 그대로 넘기면 mTLS 뒤에서도 동작합니다.

브라우저 클립보드 API 는 보안 컨텍스트(HTTPS)가 필요합니다. Nginx 443 또는 컨테이너 3001 이 그 조건을 만족합니다. 페이지가 클립보드 권한을 물어보면 허용하세요. Firefox 와 Safari 는 세션에서 호스트로 붙여넣기 전에 확인 창을 띄울 수 있습니다. HTTP 로만 열면 이 API 가 막힙니다.

사이드바의 클립보드 칸은 자동 동기화를 껐을 때의 수동 경로입니다.

## 관리 스크립트

2 vCPU 호스트에서는 기본 프로파일이 `low-power` 입니다. 화면은 JPEG 로 초당 30프레임, KWin 효과와 Baloo, KDE Connect, Discover 알림은 꺼집니다. Brave 는 GPU 래스터를 쓰지 않습니다. 소리는 켜 두고, `SELKIES_AUDIO_ENABLED=false` 이면 세션이 PipeWire 를 띄우지 않습니다. `balanced` 는 소프트웨어 H.264(`h264enc`, 내부는 코어 수만큼 나뉜 x264) 30프레임, `quality` 는 같은 인코더로 60프레임입니다. 현재 Selkies 에는 x264 preset 을 따로 지정하는 변수가 없습니다.

```bash
./webtop.sh profile low-power
./webtop.sh profile balanced
./webtop.sh profile quality
./webtop.sh variant kasm
./webtop.sh variant selkies
```

프로파일은 `deploy/.env` 를 고치고, webtop 컨테이너가 켜져 있으면 그 컨테이너만 다시 만듭니다. `WEBTOP_VARIANT=kasm` 이면 프로파일은 적용하지 않고 Selkies 전용이라고 알립니다. `variant` 는 `WEBTOP_VARIANT` 와 `IMAGE_TAG` 를 맞추고, 컨테이너가 켜져 있으면 그 태그로 다시 만듭니다.

루트의 `./webtop.sh` 가 배포에 필요한 일을 한곳에서 처리합니다. 스크립트는 심볼릭 링크를 따라 저장소 루트를 찾으므로, 어느 디렉터리에서 실행해도 `deploy/` 를 봅니다.

```bash
sudo ./webtop.sh link
# /usr/local/bin/webtop -> 이 저장소의 webtop.sh
# /etc/bash_completion.d/webtop 에 하위 명령 완료도 넣습니다
webtop status
```

root 가 아니면 링크를 만들지 않고 sudo 예를 출력합니다. `link 다른이름` 이면 `/usr/local/bin/다른이름` 이 됩니다. `cron-install` 은 링크가 아니라 저장소 안의 절대 경로를 crontab 에 넣습니다.

인자 없이 실행하면 한국어 번호 메뉴가 반복되고, 작업을 마친 뒤 Enter 로 메뉴에 돌아옵니다. 같은 일을 명령으로도 실행할 수 있습니다. 메뉴의 로그 보기는 컨테이너 이름(`webtop`, `webtop-nginx`, `webtop-certadmin`, `webtop-geoipupdate`)으로 최근 100줄을 보여주고, 실행 중이면 Ctrl+C 할 때까지 따라갑니다. Ctrl+C 는 스크립트를 끝내지 않고 메뉴로 돌아옵니다. 컨테이너가 없으면 경로와 함께 오류를 냅니다. 접속 로그는 `deploy/logs/access.log` 를 시간, 국가, CN, 요청, 상태로 보여 주고, certadmin 감사 로그와 업데이트 로그도 고를 수 있습니다.

```bash
./webtop.sh                  # 메뉴
./webtop.sh precheck
./webtop.sh env --account 123 --license '키' --countries KR,JP
./webtop.sh ca
./webtop.sh server --cn webtop.example.com --extra www.webtop.example.com
./webtop.sh client laptop
./webtop.sh client owner --admin
./webtop.sh enroll --name phone --minutes 10
./webtop.sh list
./webtop.sh revoke laptop
./webtop.sh start
./webtop.sh logs nginx
./webtop.sh logs
./webtop.sh access-log
./webtop.sh access-log certadmin
./webtop.sh check-update
./webtop.sh self-update --check
./webtop.sh self-update --yes
./webtop.sh upgrade --stash --yes
./webtop.sh login-check status
./webtop.sh login-check install
./webtop.sh version
./webtop.sh version --check
./webtop.sh variant kasm
./webtop.sh update --yes
./webtop.sh link
./webtop.sh link
./webtop.sh cron-install --schedule '0 14 * * 1' --mode check
./webtop.sh install --cn webtop.example.com --name laptop
```

`install` 은 도구 확인, `.env`(포트 포함), 선택한 포트 점검, CA, 서버 인증서, 클라이언트 인증서, 스택 시작을 순서대로 하고, 이미 끝난 단계는 건너뜁니다. 443 이 다른 프로세스에 잡혀 있으면 HTTPS 기본값을 8443 으로 제안하고, 80 이 잡혀 있으면 HTTP 리다이렉트를 끌 수 있습니다. 값은 `HTTPS_PORT` 와 `HTTP_PORT`(비우면 HTTP 포트 없음)로 `deploy/.env` 에 저장됩니다. HTTP 를 켤 때만 `deploy/compose.http.yml` 이 함께 적용됩니다. Nginx 의 HTTP 리다이렉트는 443 이 아닐 때 `https://호스트:포트` 로 보냅니다.

`update` 와 `check-update` 는 이 머신의 아키텍처에 해당하는 선택 태그(`IMAGE_TAG`, 기본 `latest`, Kasm 은 `kasm`) 다이제스트를 실행 중인 컨테이너, 로컬 이미지와 비교합니다. 같으면 받지 않습니다. 다르면 맞는 날짜 태그(`yymmdd` 또는 `kasm-yymmdd`)를 보여주고, 확인 후 pull 합니다. `check-update` 는 저장소가 `origin/main` 보다 뒤처졌는지도 함께 보여 줍니다.

`version`(`-v`, `--version`)은 네트워크 없이 한 줄을 냅니다. 예: `webtop c2351eb (2026-11-11) · kasm · image sha256:ab12cd34 · 최신`. 스크립트 git 커밋과 날짜, `WEBTOP_VARIANT`, 실행 중인 컨테이너 이미지의 짧은 다이제스트, 로그인 확인 캐시의 상태(`최신`, `업데이트 있음`, `확인 안 됨`)입니다. 컨테이너가 없으면 `not running` 입니다. 이미지에 `org.opencontainers.image.revision` 또는 `created` 라벨이 있으면 다음 줄에 보여 줍니다. `version --check` 만 캐시를 새로 고칩니다. `status` 도 같은 한 줄로 시작합니다.

대화형 SSH 로그인에서는 그 한 줄이 먼저 나옵니다. `LOGIN_SHOW_VERSION=on`(기본)이면 최신일 때도 보여주고, `off` 이면 업데이트가 있을 때만 알림의 첫 줄로 나옵니다. 비대화형 셸에는 나오지 않습니다. 저장소나 이미지가 뒤처져 있을 때만 이어서 짧은 알림을 냅니다. 기본 `LOGIN_CHECK=prompt` 는 `업데이트를 지금 진행할까요? [Y/n]` 를 묻고, Enter 는 예입니다. 15초 안에 답이 없으면 넘어가고, 다음 확인 시각까지 다시 묻지 않습니다. 예이면 `self-update --yes` 와, 이미지가 뒤처졌으면 `update --yes` 를 이어서 실행합니다. `notify` 는 명령만 보여 주고, `off` 는 끄집니다. 확인 결과는 `deploy/logs/login-check.cache` 에 남고, 기본 6시간(`LOGIN_CHECK_INTERVAL`)이 지나면 다음 로그인에서 백그라운드로 다시 확인합니다. 로그인 셸을 기다리지 않습니다. 비대화형 셸과 scp, sftp 에는 아무것도 내지 않습니다. git 이나 docker 를 실행할 수 없으면 묻지 않고 알림만 냅니다.

```bash
git pull --ff-only
sudo ./webtop.sh link
./webtop.sh login-check status
# root 가 아니면 계정 bashrc 에만 넣습니다.
./webtop.sh login-check install
./webtop.sh login-check uninstall
```

`sudo ./webtop.sh link` 는 `/usr/local/bin/webtop` 과 함께 `/etc/profile.d/webtop-update.sh` 를 넣습니다. 이미 링크만 있는 서버는 link 를 다시 실행하거나 `login-check install` 을 실행합니다.

`self-update`(`upgrade` 와 같음)는 이 체크아웃을 `origin/main` 으로 fast-forward 합니다. `git fetch` 뒤 들어올 커밋을 보여주고, `git pull --ff-only` 만 합니다. 추적 중인 파일에 로컬 변경이 있으면 그 목록을 출력하고 멈추며, 버리지 않습니다. `--stash` 는 그 추적 파일만 `git stash` 하고, `deploy/.env`, `compose.override.yml`, 인증서, `filebrowser-data` 처럼 추적되지 않은 파일은 그대로 둡니다. 가져온 범위에서 Nginx 또는 certadmin 빌드 맥락이나 compose 파일이 바뀌었고 그 컨테이너가 있으면 해당 서비스만 다시 만듭니다. `webtop.sh` 가 바뀌면 새 스크립트를 다시 실행해 이어서 처리합니다. `--check` 는 적용하지 않습니다.

`cron-install` 은 사용자 crontab 에 `webtop.sh auto-update` 를 넣습니다. 기본 시각은 월요일 14:00(로컬)입니다. 이미지 CI 는 월요일 03:17 UTC(12:17 JST)에 돌므로, 그 빌드가 끝난 뒤에 확인합니다. 이미 등록된 설치는 예전 식(월요일 06:00)을 유지하므로 `./webtop.sh cron-install` 을 다시 실행해야 14:00 으로 바뀝니다. `UPDATE_MODE=check` 이면 로그만, `apply` 이면 적용합니다. `SELF_UPDATE=on`(기본)이면 이미지를 보기 전에 저장소부터 맞추고, `off` 이면 저장소는 건너뜁니다. check 모드의 저장소 갱신도 보고만 합니다. 잠금은 `flock` 이고 기록은 `deploy/logs/update.log` 입니다.

라이선스 키와 PKCS#12 비밀번호는 메뉴에서 화면에 표시하지 않고 입력받습니다. 스택 명령은 `docker compose --env-file deploy/.env -f deploy/docker-compose.yml` 를 사용합니다. `HTTP_PORT` 가 있으면 `deploy/compose.http.yml` 을 뒤에 붙입니다. `deploy/compose.override.yml` 이 있으면 그것도 마지막에 붙입니다. `-f` 를 직접 주면 Compose 가 override 를 자동으로 읽지 않으므로, `webtop.sh` 가 파일이 있을 때만 넣습니다.

`PUID` 와 `PGID` 기본값은 1000 입니다. `sudo` 로 스크립트를 실행해도 `SUDO_UID` 가 0 이 아니면 그 값을 제안하고, 아니면 1000 입니다. `compose.override.yml` 이 `/config` 에 호스트 디렉터리를 붙이고 그 디렉터리가 있으면, 그 소유자 uid/gid 를 제안합니다. 저장된 값이 0 이면 `precheck` 와 `status` 가 경고합니다. `start` 는 대화형이면 고칠지 묻고, 비대화형이면 시작하지 않습니다. 0 으로 두면 abc 가 root 가 되고 VLC 는 `VLC is not supposed to be run as root` 로 끝납니다.

이미 쓰던 설정 디렉터리를 붙이려면 `deploy/compose.override.yml` 을 만듭니다. 나중 파일이 같은 경로의 마운트를 덮으므로 이름 있는 볼륨 대신 이 디렉터리가 `/config` 가 됩니다. 소유자는 `PUID`/`PGID` 와 같아야 합니다.

```yaml
services:
  webtop:
    volumes:
      - /docker/shark.ikenew.top/data:/config
```

## 파일 브라우저

선택 사항입니다. 기본은 꺼져 있습니다. [FileBrowser Quantum](https://github.com/gtsteffaniak/filebrowser) `ghcr.io/gtsteffaniak/filebrowser:2.0.2-stable-slim` 을 씁니다. amd64 와 arm64 이고, FFmpeg 가 없는 slim 이라 용량이 작습니다. 호스트 포트는 없습니다. 주소는 `/fi/` 이고, 데스크톱과 같은 mTLS 와 GeoIP 를 탑니다. KasmVNC 의 kclient 가 이미 `/files` 에서 자체 파일 관리자를 띄우므로 Quantum 은 그 경로를 쓰지 않습니다. `/files/` 는 webtop 으로 그대로 갑니다.

```bash
./webtop.sh filebrowser on
./webtop.sh filebrowser off
./webtop.sh filebrowser status
./webtop.sh filebrowser password
```

`on` 은 `deploy/.env` 의 `FILEBROWSER=on` 을 저장하고, Nginx 이미지를 다시 만든 뒤 compose profile `filebrowser` 로 컨테이너를 띄웁니다. Nginx 설정은 이미지 안에 있으므로 이 재빌드가 있어야 `/fi/` 가 Quantum 으로 갑니다. 이후 `start`, `restart`, `update` 도 그 프로필을 포함합니다. `off` 는 설정을 끄고 컨테이너를 지웁니다. 꺼져 있으면 Nginx 는 그대로 뜨고 `/fi/` 는 502 입니다.

보는 디렉터리는 webtop 의 `/config` 와 같습니다. `WEBTOP_CONFIG_SOURCE` 에 호스트 경로를 두면 두 서비스가 그 경로를 같이 씁니다. 비어 있고 `deploy/compose.override.yml` 이 `/config` 에 디렉터리를 붙이면 그 경로를 같이 씁니다. 예:

```bash
WEBTOP_CONFIG_SOURCE=/docker/shark.ikenew.top/data
```

데이터베이스는 `deploy/filebrowser-data/` 에 있으며 커밋하지 않습니다. 프로세스는 `PUID`/`PGID` (기본 1000, 0 은 거부) 로 돕니다.

로그인은 켜 둡니다. 비밀번호는 설정 파일에 넣지 않습니다. 첫 실행이 `admin` 의 임의 비밀번호를 로그에 한 번 남기고, 첫 로그인 때 바꾸라고 합니다.

```bash
./webtop.sh filebrowser password
```

mTLS 만으로 열고 싶으면 `FILEBROWSER_NOAUTH=true` 로 둔 뒤 `./webtop.sh filebrowser on` 으로 다시 만듭니다. 클라이언트 인증서는 그대로 필요합니다. 프록시 헤더로 사용자를 넘기는 기능은 켜지 않습니다. FileBrowser 는 인터넷에 직접 열리지 않습니다.

영상과 소리의 기본 프로그램은 두 변형 모두 VLC 입니다. `/etc/xdg/mimeapps.list` 와 `/usr/share/applications/mimeapps.list` 에 두고, 컨테이너가 시작할 때마다 `/config/.config/mimeapps.list` 의 영상/소리 항목만 `vlc.desktop` 으로 고칩니다. 다른 타입과 사용자가 적어 둔 나머지 연결은 그대로입니다. `kde-mimeapps.list` 가 있으면 같은 항목만 고칩니다.

`https://호스트/admin/` 은 클라이언트 인증서에 `OU=admin` 이 있거나 CN 이 `ADMIN_CNS` 에 있을 때만 열립니다. 메뉴의 관리자 인증서 발급 또는 `./webtop.sh client 이름 --admin` 으로 만듭니다. 그 페이지에서 인증서 목록, 발급, 폐기, 일회용 등록 링크를 처리합니다. 폐기하면 CRL 을 다시 쓰고 Nginx 가 잠시 후 다시 읽어 폐기된 인증서를 거부합니다. CA 개인키는 certadmin 컨테이너만 마운트합니다.

`/enroll/<토큰>` 은 클라이언트 인증서 없이 열리지만, 국가 제한은 그대로입니다. 첫 방문은 토큰을 `HttpOnly; Secure; SameSite=Strict` 쿠키로 옮기고 `/enroll/` 로 보냅니다. 토큰은 256비트 난수이고 해시만 저장됩니다. 기간을 생략하면 `ENROLL_TTL_SECONDS`(기본 600초, 10분)를 쓰고, 1분에서 1440분 사이로 맞춥니다. `./webtop.sh enroll --name phone --minutes 10` 처럼 분을 줄 수도 있습니다. PKCS#12 는 한 번만 발급되고 내려받는 즉시 메모리에서 지워집니다. 개인키 파일은 서버에 남기지 않습니다. 인증서 본문은 폐기를 위해 남습니다. 루트 CA 는 링크가 만료되기 전까지 같은 쿠키로 받을 수 있습니다. 페이지에 SHA-256 과 SHA-1 지문, 그리고 Windows, macOS, iOS, Android, Linux 설치 순서가 나옵니다. 자세한 절차는 [인증서 설치](docs/cert-install.md) 에 있습니다. 발급, 폐기, 등록은 `deploy/logs/certadmin.log` 에 관리자 CN, IP, 국가가 남고 비밀번호와 토큰은 남지 않습니다. Nginx 접속 로그의 `/enroll/` 과 일회용 다운로드 주소도 토큰 없이 기록합니다. 예전 `access.log` 에 토큰이 남아 있으면 그 파일을 지우고, `deploy/certs/clients/*.key` 와 `--keep` 없이 만들어 둔 `.p12` 도 기기로 옮긴 뒤 삭제하세요. 이 변경이 들어간 뒤 `self-update` 는 nginx 와 certadmin 을 다시 만듭니다.

## mTLS, GeoIP, Compose

`deploy/docker-compose.yml` 은 webtop, GeoIP 갱신, Nginx 를 띄웁니다. webtop 포트는 공개되지 않습니다.

Cloudflare 를 쓸 때는 **DNS only (회색 구름)** 만 사용하세요. 주황 구름 프록시는 TLS 를 Cloudflare 에서 끝내서 클라이언트 인증서가 Nginx 에 도달하지 않고, Nginx 가 보는 IP 도 방문자 IP 가 아니라 Cloudflare 주소가 됩니다. GeoIP 와 mTLS 가 둘 다 깨집니다.

### 1. MaxMind 라이선스

[GeoLite2](https://www.maxmind.com/en/geolite2/signup) 에서 계정 ID 와 라이선스 키를 만듭니다.

```bash
cp deploy/.env.example deploy/.env
# MAXMIND_ACCOUNT_ID, MAXMIND_LICENSE_KEY 를 채웁니다
```

`deploy/.env` 와 mmdb 파일은 커밋하지 않습니다. `geoipupdate` 가 `GeoLite2-Country` 를 받아 이름 있는 볼륨에 넣고, 기본 72시간마다 다시 받습니다. Nginx 모듈은 5분 간격으로 파일 변경을 확인해 다시 읽습니다.

허용 국가는 `ALLOWED_COUNTRIES` (기본 `KR,JP`) 입니다. 사설/루프백/링크로컬 주소는 항상 허용합니다. 그 외 공인 IP 는 **TLS 핸드셰이크 전에** stream 계층에서 연결을 끊습니다. DB 에 국가가 없으면 거부합니다. mmdb 가 없거나 깨져 있으면 Nginx 는 시작하지 않습니다. 국가와 클라이언트 IP 는 `deploy/logs/stream.log` (`allowed=0` 이 거부)와 `access.log` 에 남습니다.

VPN 앱이 보여주는 나라 이름과 MaxMind 가 그 출구 IP 에 붙인 나라는 다를 수 있습니다. `access.log` 가 `client=130.62.218.125 country="JP"` 이면 필터는 그 주소를 일본으로 본 것입니다.

```bash
./webtop.sh geo-status
./webtop.sh geo-test 130.62.218.125
```

같은 IP 의 동시 연결은 stream 에서 30개로 제한합니다. TLS 이후 요청은 IP 당 초당 30회(버스트 200), 동시 30연결입니다. 페이지가 429 로 잘리면 `deploy/nginx/nginx.conf` 의 `limit_req` / `limit_conn` 을 올리세요.

### 2. 인증서

호스트에 OpenSSL 이 있어야 합니다.

```bash
./scripts/gen-certs.sh init
# 선택: 이 CA 가 서명할 수 있는 이름만 허용. 이미 만든 CA 에는 적용되지 않습니다.
# ./scripts/gen-certs.sh init --name-constraint webtop.example.com --name-constraint 127.0.0.1
./scripts/gen-certs.sh server --cn webtop.example.com \
  --san DNS:webtop.example.com,DNS:localhost,IP:127.0.0.1
./scripts/gen-certs.sh client laptop
# 비밀번호를 지정하지 않으면 임의로 만들어 한 번만 출력합니다.
# 서버에 PKCS#12 를 남기려면: ./scripts/gen-certs.sh client laptop --keep
```

`deploy/certs/` 가 생깁니다.

- `ca/ca.crt`, `ca/ca.key` — 개인 CA. 키는 서버에만 둡니다
- `server/server.crt`, `server/server.key` — Nginx 서버 인증서
- `clients/laptop.crt` — 폐기와 CRL 에 쓰는 클라이언트 인증서. 개인키와 `.p12` 는 기본으로 남기지 않습니다
- `crl/ca.crl` — 폐기 목록

클라이언트 비밀번호는 대화형 프롬프트로 입력합니다. 비우면 임의 비밀번호를 한 번만 보여 줍니다. `--p12-pass` 와 `P12_PASS` 는 셸 기록이나 환경에 남으므로 스크립트 밖에서 쓰지 마세요. `--keep` 만 `clients/<이름>.p12` 를 0600 으로 서버에 남기고 경고합니다. 서버 인증서의 SAN 에 실제 접속 이름을 넣어야 브라우저가 이름을 맞춥니다.

이름 제약은 새 CA 를 만들 때만 넣습니다. `--name-constraint` 는 반복할 수 있고, 도메인 또는 IP(단일 주소나 CIDR)를 받습니다. 도메인 제약은 그 이름과 하위 이름을 허용합니다. 제약은 CA 인증서의 critical nameConstraints 라서 나중에 고칠 수 없습니다. CA 를 바꾸면 서버 인증서와 모든 클라이언트 인증서를 다시 발급하고, 기기에 설치한 루트도 지운 뒤 다시 설치해야 합니다. 메뉴의 CA 생성에서도 같은 질문을 하며, 비우면 제약 없는 CA 가 만들어집니다.

```bash
./webtop.sh ca --name-constraint webtop.example.com --name-constraint 127.0.0.1
```

기본 서버 인증서 SAN 에는 요청한 도메인 외에 `localhost` 와 `127.0.0.1` 이 들어갑니다. 도메인만 제약하면 그 SAN 은 `openssl verify` 와 브라우저에서 거절됩니다. 서버 인증서에 넣을 이름을 제약에 포함하거나, SAN 에서 빼세요.

### 3. 클라이언트 인증서 설치

순서는 **루트 CA 먼저**, 그 다음 클라이언트 `.p12` 입니다. 기기에 설치하는 것은 `ca.crt` 뿐이고 `ca.key` 는 서버에만 둡니다. 등록 페이지와 `/admin/` 에서 DER `.cer` 와 PEM `.crt` 를 받고, 표시된 SHA-256 과 SHA-1 지문을 기기 화면과 비교합니다. 한 글자라도 다르면 설치하지 않습니다. Windows, macOS, iOS, Android, Linux 의 저장소, Firefox 가 따로인 점, 제거와 교체는 [인증서 설치](docs/cert-install.md) 에 적어 두었습니다.

허용되지 않은 나라의 공인 IP 는 TLS ClientHello 직후 연결이 끊기고, HTTP 응답은 없습니다. 허용된 주소인데 클라이언트 인증서가 없으면 Nginx 가 `400 No required SSL certificate was sent` 로 거절하고 webtop 으로 넘기지 않습니다. 폐기된 인증서는 `400 The SSL certificate error` 입니다.

### 4. 기기를 잃었을 때

```bash
./scripts/gen-certs.sh revoke laptop
docker compose --env-file deploy/.env -f deploy/docker-compose.yml exec nginx nginx -s reload
```

`revoke` 는 해당 클라이언트 인증서를 폐기하고 CRL 을 다시 만듭니다. Nginx 는 기동/리로드 때 CRL 을 읽으므로 reload 가 필요합니다. CRL 파일은 그 자리에서 덮어씁니다. 지우고 새로 만들면 바인드 마운트가 이전 inode 를 볼 수 있습니다.

같은 이름으로 다시 발급하려면 `deploy/certs/clients/laptop.*` 를 지운 뒤 `client laptop` 을 다시 실행합니다. CA 데이터베이스는 폐기 기록을 유지합니다.

### 5. 스택 실행

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.yml up -d --build
```

`https://서버이름/` 으로 접속합니다. `/config` 는 볼륨 `webtop-config` 에 남습니다. 바인드 마운트로 바꾸려면 compose 의 `webtop-config:/config` 를 `./data:/config` 처럼 고칩니다.

## 로그

Nginx 접근 로그는 `deploy/logs` 에 쌓입니다.

- `access.log` — 시각, 클라이언트 IP, 국가 코드, 사설 IP 여부, 인증서 CN, Subject DN, 시리얼, 검증 결과, 요청, 상태
- `stream.log` — TLS 이전 연결. 국가 제한으로 끊긴 접속도 여기에 남습니다
- `error.log`

국가가 비어 있고 `private=1` 이면 사설망입니다. `verify` 는 성공 시 `SUCCESS` 입니다.

로테이션 예시는 `deploy/logrotate.example` 입니다. 경로를 고친 뒤 호스트 `/etc/logrotate.d/` 에 두고, `postrotate` 의 `nginx -s reopen` 이 로그 파일을 다시 열게 합니다.

## 업데이트

```bash
docker pull ghcr.io/krsuhjunho/webtop:latest
docker compose --env-file deploy/.env -f deploy/docker-compose.yml up -d
```

`/config` 볼륨은 유지됩니다. 이미지 쪽 fcitx/zsh 기본 파일은 홈에 같은 파일이 없을 때만 복사하므로, 이미 만든 설정은 덮어쓰지 않습니다. 주간 빌드의 날짜 태그는 UTC `yymmdd` 입니다.

Kasm 변형은 `Dockerfile.kasm` 입니다. 베이스는 `ghcr.io/linuxserver/baseimage-kasmvnc:ubuntunoble` 로 고정하고, 빌드 안에서 `apt upgrade` 합니다.

```bash
docker build -f Dockerfile.kasm -t webtop:kasm-local .
```

Selkies 를 직접 빌드할 때 amd64 기본값은 인자 없이 됩니다. arm64 는 다음처럼 베이스 태그를 넘깁니다.

```bash
docker build \
  --build-arg BASEIMAGE=ghcr.io/linuxserver/baseimage-selkies:arm64v8-ubunturesolute \
  --build-arg KWIN_LAYER=ghcr.io/linuxserver/selkies-layers:arm64v8-ubunturesolute-kwin \
  -t webtop:local .
```

GitHub Actions 는 Selkies 와 Kasm 을 각각 amd64 는 `ubuntu-24.04`, arm64 는 `ubuntu-24.04-arm` 에서 네이티브로 빌드합니다. arm 러너가 없으면 같은 워크플로가 QEMU 로 arm64 를 다시 빌드합니다. 주간 일정은 두 변형을 모두 다시 빌드합니다.

## 문제 해결

- 화면이 검으면 `--shm-size=2g` 를 확인합니다. WebSocket 이 프록시에서 막혀도 같습니다. Nginx 는 버퍼링을 끄고 타임아웃을 1시간으로 둡니다.
- 시계가 UTC 이면 `TZ=Asia/Tokyo` 인지, 볼륨에 남은 사용자 시간대 설정이 없는지 확인합니다. 컨테이너 안에서 `date` 가 JST 여야 합니다.
- 국가 제한에 걸리면 인증서 선택 창도 뜨기 전에 연결이 끊깁니다. `./webtop.sh geo-test <공인IP>` 가 MaxMind 국가를 보여 줍니다. VPN 의 가상 위치와 다를 수 있습니다. 사설 IP 에서 붙는 관리 접속은 허용됩니다. mmdb 가 없으면 Nginx 는 기동하지 않습니다 (막힌 상태가 기본).
- GeoIP 데이터베이스가 오래되면 `geoipupdate` 로그를 봅니다. 라이선스 키는 `deploy/.env` 에만 있습니다.
