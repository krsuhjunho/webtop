# Webtop

브라우저로 쓰는 Ubuntu 26.04 KDE Plasma 데스크톱입니다. [linuxserver Selkies](https://github.com/linuxserver/docker-baseimage-selkies) `baseimage-selkies:ubunturesolute` 위에 KDE를 올리고, 한국어와 일본어 입력, zsh, 자주 쓰는 CLI를 넣었습니다. 세션 스크립트는 [linuxserver/docker-webtop](https://github.com/linuxserver/docker-webtop) `ubuntu-kde` 브랜치를 바탕으로 했고, 저장소 라이선스는 GPL-3.0-only 입니다.

이미지는 `ghcr.io/krsuhjunho/webtop` 에 `linux/amd64` 와 `linux/arm64` 로 올라갑니다. 태그는 `latest`, UTC 기준 `yymmdd`, `sha-<커밋>` 입니다. `main` 푸시, 수동 실행, 매주 월요일 빌드가 베이스 이미지 갱신을 따라갑니다.

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
| `PUID` / `PGID` | `1000` | `/config` 와 `abc` 계정의 uid/gid |
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

루트의 `./webtop.sh` 가 배포에 필요한 일을 한곳에서 처리합니다. 인자 없이 실행하면 한국어 번호 메뉴가 반복되고, 작업을 마친 뒤 Enter 로 메뉴에 돌아옵니다. 같은 일을 명령으로도 실행할 수 있습니다.

```bash
./webtop.sh                  # 메뉴
./webtop.sh precheck
./webtop.sh env --account 123 --license '키' --countries KR,JP
./webtop.sh ca
./webtop.sh server --cn webtop.example.com --extra www.webtop.example.com
./webtop.sh client laptop --p12-pass '비밀번호'
./webtop.sh list
./webtop.sh revoke laptop
./webtop.sh start
./webtop.sh logs nginx
./webtop.sh check-update
./webtop.sh update --yes
./webtop.sh cron-install --schedule '0 6 * * 1' --mode check
./webtop.sh install --cn webtop.example.com --name laptop --p12-pass '비밀번호'
```

`install` 은 도구 확인, `.env`(포트 포함), 선택한 포트 점검, CA, 서버 인증서, 클라이언트 인증서, 스택 시작을 순서대로 하고, 이미 끝난 단계는 건너뜁니다. 443 이 다른 프로세스에 잡혀 있으면 HTTPS 기본값을 8443 으로 제안하고, 80 이 잡혀 있으면 HTTP 리다이렉트를 끌 수 있습니다. 값은 `HTTPS_PORT` 와 `HTTP_PORT`(비우면 HTTP 포트 없음)로 `deploy/.env` 에 저장됩니다. HTTP 를 켤 때만 `deploy/compose.http.yml` 이 함께 적용됩니다. Nginx 의 HTTP 리다이렉트는 443 이 아닐 때 `https://호스트:포트` 로 보냅니다.

`update` 와 `check-update` 는 이 머신의 아키텍처에 해당하는 `ghcr.io/krsuhjunho/webtop:latest` 다이제스트를 실행 중인 컨테이너, 로컬 이미지와 비교합니다. 같으면 받지 않습니다. 다르면 맞는 `yymmdd` 태그를 보여주고, 확인 후 pull 합니다. `cron-install` 은 사용자 crontab 에 `webtop.sh auto-update` 를 넣습니다. 기본은 월요일 06:00 이고, `UPDATE_MODE=check` 이면 로그만, `apply` 이면 새 다이제스트일 때 적용합니다. 잠금은 `flock` 이고 기록은 `deploy/logs/update.log` 입니다.

라이선스 키와 PKCS#12 비밀번호는 메뉴에서 화면에 표시하지 않고 입력받습니다. 스택 명령은 `docker compose --env-file deploy/.env -f deploy/docker-compose.yml` 를 사용합니다.

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

허용 국가는 `ALLOWED_COUNTRIES` (기본 `KR,JP`) 입니다. 사설/루프백/링크로컬 주소는 항상 허용합니다. 그 외 공인 IP 는 **TLS 핸드셰이크 전에** stream 계층에서 연결을 끊습니다. 국가 코드는 stream 로그와 HTTP 접근 로그에 남습니다.

같은 IP 의 동시 연결은 stream 에서 30개로 제한합니다. TLS 이후 요청은 IP 당 초당 30회(버스트 200), 동시 30연결입니다. 페이지가 429 로 잘리면 `deploy/nginx/nginx.conf` 의 `limit_req` / `limit_conn` 을 올리세요.

### 2. 인증서

호스트에 OpenSSL 이 있어야 합니다.

```bash
./scripts/gen-certs.sh init
./scripts/gen-certs.sh server --cn webtop.example.com \
  --san DNS:webtop.example.com,DNS:localhost,IP:127.0.0.1
./scripts/gen-certs.sh client laptop
```

`deploy/certs/` 가 생깁니다.

- `ca/ca.crt`, `ca/ca.key` — 개인 CA. 키는 서버에만 둡니다
- `server/server.crt`, `server/server.key` — Nginx 서버 인증서
- `clients/laptop.crt`, `laptop.key`, `laptop.p12` — 브라우저에 넣을 클라이언트 인증서
- `crl/ca.crl` — 폐기 목록

PKCS#12 비밀번호 기본값은 `changeit` 입니다. `P12_PASS` 또는 `--p12-pass` 로 바꿉니다. 서버 인증서의 SAN 에 실제 접속 이름을 넣어야 브라우저가 이름을 맞춥니다.

### 3. 클라이언트 인증서 설치

CA 의 `ca.crt` 도 신뢰해야 서버 경고가 사라집니다. 클라이언트 쪽에는 `laptop.p12` 를 넣습니다.

- **브라우저 (Chrome, Edge, Firefox)**: 설정 → 인증서 → 가져오기 → PKCS#12. Firefox 는 자체 저장소를 쓰므로 브라우저 안에서 가져옵니다. 사이트에 들어가면 인증서 선택 창이 뜹니다.
- **macOS**: `laptop.p12` 를 더블 클릭해 키체인에 넣습니다. 시스템 또는 로그인 키체인. CA 인증서 `ca.crt` 는 키체인 접근에서 "항상 신뢰" 로 둡니다. Safari 와 Chrome 은 키체인을 사용합니다.
- **iOS / iPadOS**: `.p12` 를 AirDrop 또는 메일로 보내고 설정 → 프로파일 다운로드에서 설치합니다. 설정 → 일반 → 정보 → 인증서 신뢰 설정에서 CA 를 루트로 켭니다. `.crt` CA 와 `.p12` 를 둘 다 설치하는 편이 낫습니다.
- **Android**: 설정 → 보안 → 인증서 설치 → VPN 및 앱 사용자 인증서에 `.p12` 를 넣습니다. CA 는 "CA 인증서" 로 따로 설치합니다. 기기 PIN 이 없을 수 있습니다.

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

직접 빌드할 때 amd64 기본값은 인자 없이 됩니다. arm64 는 다음처럼 베이스 태그를 넘깁니다.

```bash
docker build \
  --build-arg BASEIMAGE=ghcr.io/linuxserver/baseimage-selkies:arm64v8-ubunturesolute \
  --build-arg KWIN_LAYER=ghcr.io/linuxserver/selkies-layers:arm64v8-ubunturesolute-kwin \
  -t webtop:local .
```

GitHub Actions 는 amd64 를 `ubuntu-24.04`, arm64 를 `ubuntu-24.04-arm` 에서 네이티브로 빌드합니다. arm 러너가 없으면 같은 워크플로가 QEMU 로 arm64 를 다시 빌드합니다.

## 문제 해결

- 화면이 검으면 `--shm-size=2g` 를 확인합니다. WebSocket 이 프록시에서 막혀도 같습니다. Nginx 는 버퍼링을 끄고 타임아웃을 1시간으로 둡니다.
- 시계가 UTC 이면 `TZ=Asia/Tokyo` 인지, 볼륨에 남은 사용자 시간대 설정이 없는지 확인합니다. 컨테이너 안에서 `date` 가 JST 여야 합니다.
- 국가 제한에 걸리면 인증서 선택 창도 뜨기 전에 연결이 끊깁니다. 집/회사 공인 IP 가 한국 또는 일본인지 확인하세요. 사설 IP 에서 붙는 관리 접속은 허용됩니다. mmdb 가 없으면 Nginx 는 기동하지 않습니다 (막힌 상태가 기본).
- GeoIP 데이터베이스가 오래되면 `geoipupdate` 로그를 봅니다. 라이선스 키는 `deploy/.env` 에만 있습니다.
