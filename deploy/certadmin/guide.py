"""Korean install guide rendered on the enrollment and admin pages."""

import html


def esc(value):
    return html.escape(value or "", quote=True)


def detect_platform(user_agent):
    text = (user_agent or "").lower()
    if any(token in text for token in ("iphone", "ipad", "ipod")):
        return "ios"
    if "android" in text:
        return "android"
    if "windows" in text:
        return "windows"
    if "mac os" in text or "macintosh" in text:
        return "macos"
    if "linux" in text or "cros" in text:
        return "linux"
    return ""


def ca_section(prefix, sha256, sha1):
    if not sha256:
        return "<p>CA 인증서가 아직 없습니다.</p>"
    return (
        "<section><h2>루트 CA</h2>"
        "<p>기기에 넣는 파일은 <strong>CA 인증서</strong>뿐입니다. "
        "CA 개인키(ca.key)는 서버에만 있고 이 페이지에서 내려받지 않습니다.</p>"
        "<p><strong>설치 전에 지문을 비교하세요.</strong> "
        "아래 값과 기기가 보여주는 지문이 한 글자라도 다르면 설치하지 말고 파일을 지우세요.</p>"
        "<p>SHA-256</p>"
        f"<p class='fp'><code>{esc(sha256)}</code></p>"
        "<p>SHA-1. Windows 와 iOS 는 이 값을 보여 줍니다.</p>"
        f"<p class='fp'><code>{esc(sha1)}</code></p>"
        "<p>"
        f"<a href='{esc(prefix)}.cer'>CA 인증서 받기 (.cer, DER)</a>"
        " · "
        f"<a href='{esc(prefix)}.crt'>CA 인증서 받기 (.crt, PEM)</a>"
        "</p></section>"
    )


def install_guide(platform):
    def section(key, title, body):
        opened = " open" if platform == key else ""
        return f"<details{opened}><summary>{title}</summary>{body}</details>"

    windows = """
<ol>
<li>.cer 를 받습니다. 페이지의 SHA-256 과 SHA-1 을 비교합니다. 다르면 파일을 지웁니다.</li>
<li>certmgr.msc 를 엽니다. 신뢰할 수 있는 루트 인증 기관 → 인증서에서 우클릭 → 모든 작업 → 가져오기. .cer 를 고르고 저장소는 신뢰할 수 있는 루트 인증 기관으로 둡니다. 현재 사용자 저장소면 브라우저에 충분합니다.</li>
<li>보안 경고의 지문(SHA-1)을 페이지와 다시 비교한 뒤 설치합니다.</li>
<li>그 다음 .p12 를 더블 클릭합니다. 저장 위치는 현재 사용자, 저장소는 개인입니다. 이 페이지의 비밀번호를 입력합니다.</li>
<li>Edge, Chrome, Brave 는 Windows 인증서 저장소를 사용합니다. 사이트에 들어가면 인증서 선택 창이 뜹니다.</li>
<li>Firefox 는 저장소가 따로입니다. 설정 → 개인 정보 및 보안 → 인증서 → 인증서 보기에서 인증 기관에 CA 를 가져오고(웹 사이트 신뢰), 내 인증서에 .p12 를 가져옵니다. about:config 의 security.enterprise_roots.enabled 를 true 로 두면 OS 루트를 신뢰하지만, 클라이언트 인증서는 여전히 Firefox 안에 넣어야 합니다.</li>
<li>창이 안 뜨면 브라우저를 완전히 종료했다가 다시 열고, inetcpl.cpl → 내용 → SSL 상태 지우기를 실행합니다.</li>
<li>제거와 교체: certmgr.msc 의 신뢰된 루트에서 이 CA 를, 개인에서 클라이언트 인증서를 삭제합니다. 새 CA 는 루트부터 다시 설치합니다.</li>
</ol>
"""
    macos = """
<ol>
<li>.cer 또는 .crt 를 받습니다. 지문을 비교합니다.</li>
<li>키체인 접근에서 시스템 키체인을 고르고 인증서 파일을 끌어 놓습니다. 인증서를 더블 클릭 → 신뢰 → SSL 을 항상 신뢰로 바꿉니다. 이 창의 지문도 페이지와 비교합니다.</li>
<li>그 다음 .p12 를 더블 클릭해 로그인 키체인에 넣습니다. 이 페이지의 비밀번호를 입력합니다.</li>
<li>Safari, Chrome, Brave 는 키체인을 사용합니다. 사이트에 접속하면 클라이언트 인증서를 고르는 창이 뜹니다.</li>
<li>Firefox 는 설정 → 개인 정보 및 보안 → 인증서에서 CA 와 .p12 를 각각 가져옵니다.</li>
<li>창이 안 뜨면 브라우저를 완전히 종료했다가 다시 엽니다.</li>
<li>제거와 교체: 키체인 접근에서 시스템 키체인의 CA 와 로그인 키체인의 개인 인증서를 삭제합니다. 새 CA 는 다시 항상 신뢰로 넣습니다.</li>
</ol>
"""
    ios = """
<ol>
<li>Safari 로 이 페이지를 열고 .cer 를 받습니다. 설정 앱의 프로파일 다운로드됨에서 설치합니다. 지문을 페이지와 비교합니다.</li>
<li>설정 → 일반 → 정보 → 인증서 신뢰 설정에서 이 루트의 전체 신뢰를 켭니다. 여기의 지문도 비교합니다. 이 스위치를 켜야 Safari 가 서버를 신뢰합니다.</li>
<li>그 다음 .p12 를 받아 프로파일로 설치합니다. 비밀번호는 이 페이지에 표시된 값입니다.</li>
<li>Safari 가 사이트에서 클라이언트 인증서를 묻습니다. iOS 의 Chrome 도 같은 프로파일을 사용합니다.</li>
<li>창이 안 뜨면 Safari 를 앱 전환 화면에서 완전히 닫고, 프로파일 설치와 전체 신뢰가 켜져 있는지 확인한 뒤 다시 엽니다.</li>
<li>제거와 교체: 설정 → 일반 → VPN 및 기기 관리에서 CA 프로파일과 .p12 프로파일을 삭제합니다. 새 프로파일을 설치한 뒤 전체 신뢰를 다시 켭니다.</li>
</ol>
"""
    android = """
<ol>
<li>설정 → 보안 → 암호화 및 사용자 인증 정보 → 인증서 설치에서 CA 인증서를 고르고 .cer 를 넣습니다. 기기마다 보안 및 개인정보 보호 → 기타 보안 설정 → 인증서 설치처럼 메뉴 이름이 다릅니다. 화면에 나온 지문을 페이지와 비교합니다.</li>
<li>이 인증서는 사용자 CA 입니다. Chrome 과 Brave 는 사용자 CA 를 신뢰합니다. 모든 앱이 그렇지는 않아서, 시스템 CA 만 보는 앱은 이 루트로 서버를 신뢰하지 않을 수 있습니다.</li>
<li>그 다음 같은 메뉴에서 VPN 및 앱 사용자 인증서로 .p12 를 설치합니다. 비밀번호를 입력합니다.</li>
<li>Chrome 또는 Brave 로 접속하면 클라이언트 인증서 선택 창이 뜹니다.</li>
<li>창이 안 뜨면 브라우저를 강제 종료하고, 사용자 인증 정보에 인증서가 있는지 확인한 뒤 사이트 데이터를 지우고 다시 엽니다.</li>
<li>제거와 교체: 사용자 인증 정보에서 이 CA 와 사용자 인증서를 각각 삭제합니다. CA 를 먼저, .p12 를 나중에 다시 설치합니다.</li>
</ol>
"""
    linux = """
<ol>
<li>PEM .crt 를 받습니다. <code>openssl x509 -in webtop-ca.crt -noout -fingerprint -sha256</code> 결과가 페이지의 SHA-256 과 같은지 확인합니다.</li>
<li>Ubuntu 시스템 신뢰: .crt 를 <code>/usr/local/share/ca-certificates/webtop-ca.crt</code> 로 복사하고 <code>sudo update-ca-certificates</code> 를 실행합니다. 확장자는 .crt 여야 합니다. curl 과 시스템 도구가 이 루트를 신뢰합니다.</li>
<li>Chrome 과 Brave 는 NSS 를 씁니다. <code>mkdir -p ~/.pki/nssdb</code> 후 데이터베이스가 없으면 <code>certutil -d sql:$HOME/.pki/nssdb -N --empty-password</code> 로 만듭니다. CA 는 <code>certutil -d sql:$HOME/.pki/nssdb -A -n "Webtop CA" -t "C,," -i webtop-ca.crt</code> 입니다. .p12 는 <code>pk12util -d sql:$HOME/.pki/nssdb -i client.p12</code> 입니다.</li>
<li>Firefox 는 프로필마다 저장소가 따로입니다. 설정 → 개인 정보 및 보안 → 인증서에서 CA 와 .p12 를 가져옵니다. 시스템 저장소나 ~/.pki/nssdb 만으로는 Firefox 에 들어가지 않습니다.</li>
<li>창이 안 뜨면 브라우저를 완전히 종료했다가 다시 열고, <code>certutil -d sql:$HOME/.pki/nssdb -L</code> 로 CA(C,,)와 클라이언트 인증서가 보이는지 확인합니다.</li>
<li>제거와 교체: webtop-ca.crt 를 지우고 <code>sudo update-ca-certificates --fresh</code> 를 실행합니다. NSS 에서는 <code>certutil -d sql:$HOME/.pki/nssdb -D -n "Webtop CA"</code> 로 지웁니다. 클라이언트 인증서 닉네임도 -L 로 확인한 뒤 -D 로 지웁니다. 새 CA 를 다시 넣은 다음 .p12 를 가져옵니다.</li>
</ol>
"""
    return (
        "<h2>설치 순서</h2>"
        "<p>항상 <strong>루트 CA 를 먼저</strong> 설치하고, 그 다음 클라이언트 .p12 를 설치합니다. "
        "설치하는 것은 CA 인증서뿐입니다. ca.key 는 받지 않습니다. "
        "지문이 다르면 설치하지 마세요. CA 를 바꾸면 서버 인증서와 모든 클라이언트 인증서를 다시 발급하고, "
        "기기에서는 이전 루트와 이전 .p12 를 지운 뒤 새 루트부터 다시 설치합니다.</p>"
        "<p>브라우저가 클라이언트 인증서를 묻지 않으면 브라우저를 완전히 종료했다가 다시 열고, "
        "SSL 상태를 지운 뒤, 인증서가 개인 저장소에 있는지 확인합니다. "
        "국가 제한에 걸린 주소는 선택 창이 뜨기 전에 연결이 끊깁니다.</p>"
        + section("windows", "Windows", windows)
        + section("macos", "macOS", macos)
        + section("ios", "iOS / iPadOS", ios)
        + section("android", "Android", android)
        + section("linux", "Linux", linux)
    )
